-- =====================================================================
-- VISITAS AOS CARROS (página gestao-integrada.github.io/visitas/)
-- O pessoal da Caliman vê as ocorrências abertas e avisa/propõe horário:
--   "o carro 36 vai estar no terminal entre 11:00 e 13:00, consegue vir olhar?"
--   "o carro 80 mudou de turno, está na garagem até 16:30".
-- Você (equipe) confirma, recusa, marca ciente/visitei e conversa por recado.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run.
-- Pode rodar de novo sem perder dados (só recria as funções).
-- Depende de: central-acessos.sql, solicitacoes.sql (usa a mesma senha e a
--             mesma chave do robô de e-mail) e ocorrencias.sql.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.vis_pessoas (            -- quem da Caliman entra (pelo celular)
  id            bigserial primary key,
  nome          text not null,
  celular       text not null unique check (celular ~ '^\d{10,11}$'),   -- DDD + número, só dígitos
  empresa       text not null default 'Caliman',
  email         text,                                       -- opcional: recebe a resposta por e-mail
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  ultimo_acesso timestamptz
);

alter table public.vis_pessoas add column if not exists matricula text;

create table if not exists public.vis_sessoes (
  token      text primary key,
  pessoa_id  bigint not null references public.vis_pessoas(id) on delete cascade,
  expira_em  timestamptz not null
);

create table if not exists public.vis_propostas (
  id             bigserial primary key,
  pessoa_id      bigint references public.vis_pessoas(id) on delete set null,
  autor          text not null,                             -- nome de quem mandou
  tipo           text not null default 'visita' check (tipo in ('visita', 'mudanca', 'aviso')),
  tags           text[] not null default '{}',              -- carros (mesma TAG da vistoria: 2 dígitos)
  local          text,                                      -- Terminal, Garagem ou o que escreverem
  dia            date not null,
  hora_ini       time,
  hora_fim       time,
  recado         text check (length(recado) <= 1000),
  status         text not null default 'pendente'
                 check (status in ('pendente', 'confirmada', 'recusada', 'ciente', 'cancelada', 'feita')),
  hora_combinada text check (length(hora_combinada) <= 40),  -- ex.: "11:30" quando você ajusta o horário
  resposta       text check (length(resposta) <= 1000),
  respondido_por text,
  respondido_em  timestamptz,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index if not exists vis_propostas_dia on public.vis_propostas (dia desc, id desc);
-- chave secreta do pedido: vai só no e-mail para você responder com 1 toque, sem senha
alter table public.vis_propostas add column if not exists chave_resposta text unique default encode(extensions.gen_random_bytes(16), 'hex');

create table if not exists public.vis_mensagens (
  id           bigserial primary key,
  proposta_id  bigint not null references public.vis_propostas(id) on delete cascade,
  ts           timestamptz not null default now(),
  quem         text,
  lado         text not null check (lado in ('caliman', 'equipe')),
  texto        text not null check (length(texto) <= 1000)
);
create index if not exists vis_mensagens_prop on public.vis_mensagens (proposta_id, ts);

-- fila de e-mails que o robô (Apps Script) manda
create table if not exists public.vis_avisos (
  id           bigserial primary key,
  proposta_id  bigint references public.vis_propostas(id) on delete cascade,
  para         text not null check (para in ('dono', 'pessoa')),   -- dono = você (conta do robô)
  email        text,                                                -- só quando para = pessoa
  assunto      text not null,
  texto        text not null,
  criado_em    timestamptz not null default now(),
  enviado_em   timestamptz,
  tentativas   int not null default 0,
  erro         text
);
create index if not exists vis_avisos_fila on public.vis_avisos (enviado_em, id);

create table if not exists public.vis_config (
  id             int primary key default 1 check (id = 1),
  nome_dono      text not null default 'Mizael',
  dias_semana    int[] not null default '{1,4}',     -- 0=dom 1=seg … 6=sáb (dias em que você está na mina)
  whatsapp_dono  text,                               -- opcional: botão "mandar também no WhatsApp"
  locais         text[] not null default '{Terminal,Garagem}',
  link           text not null default 'https://gestao-integrada.github.io/visitas/'
);
insert into public.vis_config (id) values (1) on conflict (id) do nothing;
-- agenda da semana (onde você está em cada dia e o horário); a Caliman vê isso na página
alter table public.vis_config add column if not exists agenda jsonb not null default '[
  {"d":1,"onde":"Mina","ini":"08:00","fim":"17:00","obs":"pode ir ao terminal"},
  {"d":2,"onde":"Garagem","ini":"08:00","fim":"17:00","obs":""},
  {"d":3,"onde":"Mina","ini":"08:00","fim":"17:00","obs":"nem sempre vai ao terminal"},
  {"d":4,"onde":"Mina","ini":"08:00","fim":"17:00","obs":"pode ir ao terminal"},
  {"d":5,"onde":"Garagem","ini":"08:00","fim":"17:00","obs":""}]'::jsonb;

-- ocorrências que NÃO aparecem para a Caliman (só se resolvem trocando o celular):
-- automático pelo texto (bateria inchada/estufada, tela trincada/quebrada/rachada) ou escolhido na mão pela equipe
create table if not exists public.vis_ocultar (
  ocorrencia_id bigint primary key,
  oculta        boolean not null,          -- true = esconder, false = mostrar mesmo que o texto bata
  por           text,
  em            timestamptz not null default now()
);
alter table public.vis_ocultar enable row level security;
revoke all on public.vis_ocultar from anon, authenticated;

drop function if exists public._vis_oculta(text, text);
create or replace function public._vis_oculta_auto(p_problema text) returns boolean
language sql immutable as $$
  select coalesce(p_problema, '') ~* '(inchad|estufad|trincad|rachad|tela quebrad|quebrou a tela|tela partid|carca[cç]a)'
$$;
create or replace function public._vis_oculta(p_id bigint, p_problema text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select oculta from vis_ocultar where ocorrencia_id = p_id), public._vis_oculta_auto(p_problema))
$$;

alter table public.vis_pessoas   enable row level security;   -- sem policy: só pelas funções
alter table public.vis_sessoes   enable row level security;
alter table public.vis_propostas enable row level security;
alter table public.vis_mensagens enable row level security;
alter table public.vis_avisos    enable row level security;
alter table public.vis_config    enable row level security;
revoke all on public.vis_pessoas, public.vis_sessoes, public.vis_propostas, public.vis_mensagens,
  public.vis_avisos, public.vis_config from anon, authenticated;

-- ---------------------------------------------------------------- auxiliares (internas)
create or replace function public._vis_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Belem')::date $$;

create or replace function public._vis_cel(p text) returns text
language sql immutable as $$
  select case when length(d) in (12, 13) and d like '55%' then substr(d, 3) else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

-- Quem é o dono do token: {tipo: caliman|equipe, nome, pessoa_id, admin}
create or replace function public._vis_quem(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p vis_pessoas; q jsonb;
begin
  if p_token like 'tfv_%' then
    select pe.* into p from vis_sessoes s join vis_pessoas pe on pe.id = s.pessoa_id
     where s.token = p_token and s.expira_em > now() and pe.ativo;
    if p.id is not null then
      update vis_pessoas set ultimo_acesso = now() where id = p.id;
      return jsonb_build_object('tipo', 'caliman', 'nome', p.nome, 'pessoa_id', p.id, 'empresa', p.empresa, 'admin', false);
    end if;
    return null;
  end if;
  -- equipe: a mesma sessão do quadro de demandas (senha pessoal da Central ou senha de gestores)
  q := public._sol_quem(p_token);
  if q is not null and q->>'tipo' = 'interno' and coalesce((q->>'edita')::boolean, false) then
    return jsonb_build_object('tipo', 'equipe', 'nome', q->>'nome', 'admin', coalesce((q->>'admin')::boolean, false));
  end if;
  return null;
end $$;

create or replace function public._vis_exige(p_token text, p_tipo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_quem(p_token);
begin
  if q is null then raise exception 'sessao' using errcode = '28000'; end if;
  if p_tipo is not null and q->>'tipo' <> p_tipo then raise exception 'Isso é só para a equipe.'; end if;
  return q;
end $$;

-- frase pronta da proposta (vai no e-mail e no WhatsApp)
create or replace function public._vis_frase(v public.vis_propostas) returns text
language sql stable as $$
  select concat_ws(' · ',
    case when cardinality(v.tags) = 0 then null
         when cardinality(v.tags) = 1 then 'Carro ' || v.tags[1]
         else 'Carros ' || array_to_string(v.tags[1:cardinality(v.tags) - 1], ', ') || ' e ' || v.tags[cardinality(v.tags)] end,
    v.local,
    case when v.dia = public._vis_hoje() then 'hoje, ' when v.dia = public._vis_hoje() + 1 then 'amanhã, ' else '' end ||
      (array['dom','seg','ter','qua','qui','sex','sáb'])[extract(dow from v.dia)::int + 1] || ' ' || to_char(v.dia, 'DD/MM'),
    case when v.hora_ini is not null and v.hora_fim is not null then 'das ' || to_char(v.hora_ini, 'HH24:MI') || ' às ' || to_char(v.hora_fim, 'HH24:MI')
         when v.hora_ini is not null then 'a partir das ' || to_char(v.hora_ini, 'HH24:MI')
         when v.hora_fim is not null then 'até as ' || to_char(v.hora_fim, 'HH24:MI') end)
$$;

create or replace function public._vis_json(v public.vis_propostas, p_equipe boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select (to_jsonb(v) - 'chave_resposta') || jsonb_build_object(
    'frase', public._vis_frase(v),
    'celular', case when p_equipe then (select celular from vis_pessoas where id = v.pessoa_id) end,
    'mensagens', coalesce((select jsonb_agg(jsonb_build_object('ts', m.ts, 'quem', m.quem, 'lado', m.lado, 'texto', m.texto) order by m.ts)
                           from vis_mensagens m where m.proposta_id = v.id), '[]'::jsonb))
$$;

-- coloca um e-mail na fila do robô
create or replace function public._vis_avisar(p_prop bigint, p_para text, p_email text, p_assunto text, p_texto text) returns void
language sql security definer set search_path = public as $$
  insert into vis_avisos (proposta_id, para, email, assunto, texto) values (p_prop, p_para, p_email, left(p_assunto, 200), p_texto);
$$;

revoke execute on function public._vis_oculta(bigint, text) from public, anon, authenticated;
-- aviso para a pessoa da Caliman: WhatsApp (celular do cadastro, pelo robô da TV Box) e e-mail se tiver
alter table public.vis_avisos add column if not exists numero text;
create or replace function public._vis_avisar_pessoa(v public.vis_propostas, p_assunto text, p_texto text) returns void
language sql security definer set search_path = public as $$
  insert into vis_avisos (proposta_id, para, email, numero, assunto, texto)
  select v.id, 'pessoa', pe.email, pe.celular, left(p_assunto, 200), p_texto
  from vis_pessoas pe where pe.id = v.pessoa_id and pe.ativo;
$$;
revoke execute on function public._vis_avisar_pessoa(public.vis_propostas, text, text) from public, anon, authenticated;

revoke execute on function public._vis_quem(text), public._vis_exige(text, text),
  public._vis_avisar(bigint, text, text, text, text), public._vis_json(public.vis_propostas, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- entrar / sessão / sair
create or replace function public.vis_entrar(p_celular text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare c text := public._vis_cel(p_celular); p vis_pessoas; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'visitas'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  if length(c) not in (10, 11) then
    return json_build_object('erro', 'Digite o DDD + número do celular (ex.: 91 98888-7777).');
  end if;
  select * into p from vis_pessoas where celular = c and ativo;
  if p.id is null then
    perform public._central_log(null, null, 'senha_errada', 'visitas', 'Celular não cadastrado: final ' || right(c, 4));
    return json_build_object('erro', 'Esse celular não está cadastrado. Peça para o ' ||
      (select nome_dono from vis_config where id = 1) || ' liberar o seu número.');
  end if;
  tk := 'tfv_' || encode(gen_random_bytes(24), 'hex');
  insert into vis_sessoes (token, pessoa_id, expira_em) values (tk, p.id, now() + interval '120 days');
  delete from vis_sessoes where expira_em < now();
  perform public._central_log(null, p.nome || ' (' || p.empresa || ')', 'entrou', 'visitas', 'Entrou na página de visitas');
  return (jsonb_build_object('token', tk) || public._vis_quem(tk))::json;
end $$;

create or replace function public.vis_sessao(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_quem(p_token);
begin
  if q is null then return json_build_object('erro', 'sessao'); end if;
  return q::json;
end $$;

create or replace function public.vis_sair(p_token text) returns text
language plpgsql security definer set search_path = public as $$
begin
  delete from vis_sessoes where token = p_token;   -- sessão da equipe é a mesma do quadro: não apaga aqui
  return 'ok';
end $$;

-- ---------------------------------------------------------------- tela (tudo de uma vez)
-- ---------------------------------------------------------------- rotas vigiadas: as que VOCÊ escolhe (ADM, turno...) e que precisam subir todo dia
-- Dados: tabela viagens (coleta TFleet de hora em hora). Uma rota = linha + sentido + horário previsto.
create table if not exists public.vis_rotas_vigiadas (
  id         bigserial primary key,
  linha      text not null,
  tipo       text not null,                      -- IDA / VOLTA
  prev       text not null,                      -- horário previsto (HH:MI) que identifica a viagem
  hora       time not null,                      -- horário em que costuma sair (a partir dele + 1 h, cobra)
  dias       text not null default 'uteis' check (dias in ('uteis', 'todos', 'fds')),
  grupo      text,                               -- ADM, TURNO... (só para organizar)
  criado_em  timestamptz not null default now(),
  unique (linha, tipo, prev)
);
alter table public.vis_rotas_vigiadas enable row level security;
revoke all on public.vis_rotas_vigiadas from anon, authenticated;

create or replace function public._vis_prev(p_tipo text, p_bruto jsonb, p_hora time) returns text
language sql immutable as $$
  select coalesce(lpad(substring(case when upper(p_tipo) = 'VOLTA' then p_bruto->>'saidaprevista' else p_bruto->>'entradaprevista' end
                                 from '(\d{1,2}:\d{2})'), 5, '0'),
                  to_char(date_trunc('hour', p_hora) + interval '30 min' * floor(extract(minute from p_hora) / 30), 'HH24:MI'))
$$;

-- lista para escolher (equipe): tudo que rodou nos últimos 14 dias
create or replace function public.vis_rotas_candidatas(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe'); r jsonb;
begin
  if to_regclass('public.viagens') is null then return '[]'::jsonb; end if;
  with v as (select linha, upper(coalesce(tipo, '')) as tipo, public._vis_prev(tipo, bruto, hora_saida) as prev, data_local, hora_saida,
                    frota, coalesce(tipolinha, '') as tipolinha
               from viagens where data_local >= public._vis_hoje() - 14 and linha is not null and hora_saida is not null),
  g as (select linha, tipo, prev, count(distinct data_local) as vezes, percentile_disc(0.5) within group (order by hora_saida) as hora,
               mode() within group (order by frota) as frota, mode() within group (order by tipolinha) as tipolinha
          from v group by linha, tipo, prev)
  select coalesce(jsonb_agg(jsonb_build_object('linha', coalesce(g.linha, w.linha), 'tipo', coalesce(g.tipo, w.tipo), 'prev', coalesce(g.prev, w.prev),
           'hora', to_char(coalesce(g.hora, w.hora), 'HH24:MI'), 'vezes', coalesce(g.vezes, 0), 'frota', g.frota,
           'grupo', coalesce(w.grupo, nullif(g.tipolinha, '')), 'vigiada', w.id is not null, 'dias', coalesce(w.dias, 'uteis'))
           order by coalesce(w.grupo, g.tipolinha), coalesce(g.hora, w.hora), coalesce(g.linha, w.linha)), '[]'::jsonb) into r
    from g full join vis_rotas_vigiadas w on w.linha = g.linha and w.tipo = g.tipo and w.prev = g.prev
   where g.vezes >= 2 or w.id is not null;
  return r;
end $$;

create or replace function public.vis_rotas_salvar(p_token text, p_lista jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe');
begin
  delete from vis_rotas_vigiadas where true;   -- Supabase exige WHERE no DELETE
  insert into vis_rotas_vigiadas (linha, tipo, prev, hora, dias, grupo)
  select distinct on (x->>'linha', upper(x->>'tipo'), x->>'prev') x->>'linha', upper(x->>'tipo'), x->>'prev', (x->>'hora')::time,
         case when x->>'dias' in ('uteis', 'todos', 'fds') then x->>'dias' else 'uteis' end, nullif(left(trim(x->>'grupo'), 30), '')
    from jsonb_array_elements(coalesce(p_lista, '[]'::jsonb)) x
   where coalesce(x->>'linha', '') <> '' and coalesce(x->>'prev', '') <> '' and coalesce(x->>'hora', '') <> '';
  return 'ok';
end $$;
grant execute on function public.vis_rotas_candidatas(text), public.vis_rotas_salvar(text, jsonb) to anon, authenticated;

-- situação de HOJE de cada rota vigiada: subiu / nao_subiu (passou 1 h do horário) / aguardando
create or replace function public._vis_rotas_pendentes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare hoje date := public._vis_hoje(); agora time := (now() at time zone 'America/Belem')::time;
        fds boolean := extract(isodow from public._vis_hoje()) in (6, 7); ult timestamptz; todas jsonb; n int;
begin
  if to_regclass('public.viagens') is null then return null; end if;
  select count(*) into n from vis_rotas_vigiadas;
  select max(coletado_em) into ult from viagens;
  select coalesce(jsonb_agg(x order by x->>'hora', x->>'linha'), '[]'::jsonb) into todas from (
    select jsonb_build_object('linha', w.linha, 'tipo', w.tipo, 'hora', to_char(w.hora, 'HH24:MI'), 'grupo', w.grupo,
             'frota', u.frota, 'motorista', u.motorista, 'ult_dia', u.data_local, 'ult_hora', to_char(u.hora_saida, 'HH24:MI'),
             'hoje_hora', to_char(t.hora_saida, 'HH24:MI'), 'hoje_frota', t.frota, 'hoje_motorista', t.motorista,
             'situacao', case when t.hora_saida is not null then 'subiu'
                              when agora > w.hora + interval '60 min' and w.hora < time '23:00' then 'nao_subiu'
                              else 'aguardando' end) as x
      from vis_rotas_vigiadas w
      left join lateral (select v.frota, v.motorista, v.data_local, v.hora_saida from viagens v
                          where v.linha = w.linha and upper(v.tipo) = w.tipo and v.data_local >= hoje - 14 and v.data_local < hoje
                            and public._vis_prev(v.tipo, v.bruto, v.hora_saida) = w.prev
                          order by v.data_local desc, v.hora_saida desc limit 1) u on true
      left join lateral (select v.frota, v.motorista, v.hora_saida from viagens v
                          where v.data_local = hoje and v.linha = w.linha and upper(v.tipo) = w.tipo
                            and (public._vis_prev(v.tipo, v.bruto, v.hora_saida) = w.prev
                                 or abs(extract(epoch from v.hora_saida - w.hora)) < 5400)
                          order by abs(extract(epoch from v.hora_saida - w.hora)) limit 1) t on true
     where w.dias = 'todos' or (w.dias = 'uteis' and not fds) or (w.dias = 'fds' and fds)) z;
  return jsonb_build_object('lista', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(todas) e where e->>'situacao' = 'nao_subiu'),
    'todas', todas, 'vigiadas', n, 'coleta', ult, 'proxima', ult + interval '1 hour', 'coleta_ok', ult > now() - interval '3 hours');
end $$;
revoke execute on function public._vis_rotas_pendentes() from public, anon, authenticated;

create or replace function public.vis_painel(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token); eq boolean := q->>'tipo' = 'equipe'; oc jsonb;
begin
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'tag', o.tag, 'categoria', o.categoria, 'problema', o.problema,
             'status', o.status, 'prioridade', o.prioridade, 'reincidencias', o.reincidencias,
             'desde', coalesce(o.primeira_msg_em, o.criado_em), 'oculta', public._vis_oculta(o.id, o.problema), 'oculta_auto', public._vis_oculta_auto(o.problema)) order by o.tag, o.criado_em), '[]'::jsonb)
      into oc
      from v_ocorrencias_cruzadas o where o.status in ('aberta', 'em_andamento') and o.tag is not null
        and (eq or not public._vis_oculta(o.id, o.problema));
  exception when others then      -- view antiga/sem prioridade: lê direto da tabela
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'tag', o.tag, 'categoria', o.categoria, 'problema', o.problema,
             'status', o.status, 'prioridade', o.urgencia, 'reincidencias', o.reincidencias,
             'desde', coalesce(o.primeira_msg_em, o.criado_em), 'oculta', public._vis_oculta(o.id, o.problema), 'oculta_auto', public._vis_oculta_auto(o.problema)) order by o.tag, o.criado_em), '[]'::jsonb)
      into oc
      from ocorrencias o where o.status in ('aberta', 'em_andamento') and o.tag is not null
        and (eq or not public._vis_oculta(o.id, o.problema));
  end;
  return json_build_object(
    'quem', q,
    'hoje', public._vis_hoje(),
    'config', (select jsonb_build_object('nome_dono', c.nome_dono, 'dias_semana', c.dias_semana,
                 'whatsapp_dono', c.whatsapp_dono, 'locais', c.locais, 'agenda', c.agenda) from vis_config c where c.id = 1),
    'ocorrencias', oc,
    'rotas', public._vis_rotas_pendentes(),
    'propostas', coalesce((select jsonb_agg(public._vis_json(v, eq) order by v.dia desc, v.id desc)
                 from vis_propostas v
                 where v.dia >= public._vis_hoje() - 30 or v.status = 'pendente'), '[]'::jsonb),
    'pessoas', case when eq then coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'celular', p.celular, 'matricula', p.matricula,
                 'empresa', p.empresa, 'email', p.email, 'ativo', p.ativo, 'ultimo_acesso', p.ultimo_acesso) order by p.ativo desc, p.nome)
                 from vis_pessoas p), '[]'::jsonb) end);
end $$;

-- ---------------------------------------------------------------- Caliman: propor / cancelar
create or replace function public.vis_propor(p_token text, p_dados jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token); v vis_propostas; tg text[]; d date; hi time; hf time; t text;
begin
  t := coalesce(p_dados->>'tipo', 'visita');
  if t not in ('visita', 'mudanca', 'aviso') then raise exception 'Tipo inválido.'; end if;
  select coalesce(array_agg(distinct public.normaliza_tag(x)) filter (where public.normaliza_tag(x) is not null), '{}')
    into tg from jsonb_array_elements_text(coalesce(p_dados->'tags', '[]'::jsonb)) x;
  if cardinality(tg) = 0 and t <> 'aviso' then raise exception 'Escolha pelo menos um carro.'; end if;
  if cardinality(tg) > 30 then raise exception 'Carros demais numa proposta só.'; end if;
  d := nullif(p_dados->>'dia', '')::date;
  if d is null then raise exception 'Escolha o dia.'; end if;
  if d < public._vis_hoje() - 1 or d > public._vis_hoje() + 60 then raise exception 'Dia fora do período (de ontem até 60 dias).'; end if;
  hi := nullif(p_dados->>'hora_ini', '')::time;
  hf := nullif(p_dados->>'hora_fim', '')::time;
  if hi is not null and hf is not null and hf <= hi then raise exception 'O horário final precisa ser depois do inicial.'; end if;
  if t = 'visita' and hi is null and hf is null then raise exception 'Informe o horário em que o carro vai estar lá.'; end if;
  insert into vis_propostas (pessoa_id, autor, tipo, tags, local, dia, hora_ini, hora_fim, recado)
  values ((q->>'pessoa_id')::bigint, q->>'nome', t, coalesce((select array_agg(x order by x) from unnest(tg) x), '{}'),
          nullif(left(trim(p_dados->>'local'), 60), ''), d, hi, hf, nullif(left(trim(p_dados->>'recado'), 1000), ''))
  returning * into v;
  if q->>'tipo' = 'caliman' then
    perform public._vis_avisar(v.id, 'dono', null,
      case t when 'visita' then '[Visita] ' || v.autor || ' pergunta se você consegue ir: '
             when 'mudanca' then '[Carro mudou] ' || v.autor || ': '
             else '[Aviso] ' || v.autor || ': ' end || public._vis_frase(v),
      v.autor || ' (' || coalesce(q->>'empresa', 'Caliman') || ') mandou:' || chr(10) || chr(10) ||
      case t when 'visita' then public._vis_frase(v) || '. Consegue vir olhar?'
             when 'mudanca' then 'Mudou de lugar/turno: ' || public._vis_frase(v) || '.'
             else coalesce(public._vis_frase(v), '') end ||
      coalesce(chr(10) || chr(10) || 'Recado: ' || v.recado, ''));
  end if;
  return v.id;
end $$;

create or replace function public.vis_cancelar(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token); v vis_propostas;
begin
  select * into v from vis_propostas where id = p_id;
  if v.id is null then raise exception 'Não encontrei esse pedido.'; end if;
  if q->>'tipo' = 'caliman' and v.pessoa_id is distinct from (q->>'pessoa_id')::bigint then
    raise exception 'Só quem mandou pode cancelar.';
  end if;
  if v.status in ('cancelada', 'feita') then return 'ok'; end if;
  update vis_propostas set status = 'cancelada', atualizado_em = now() where id = p_id;
  insert into vis_mensagens (proposta_id, quem, lado, texto)
    values (p_id, q->>'nome', case when q->>'tipo' = 'caliman' then 'caliman' else 'equipe' end, 'Cancelou o pedido.');
  if q->>'tipo' = 'caliman' and v.status in ('pendente', 'confirmada') then
    perform public._vis_avisar(v.id, 'dono', null, '[Cancelado] ' || v.autor || ': ' || public._vis_frase(v),
      v.autor || ' cancelou: ' || public._vis_frase(v) || '.');
  end if;
  return 'ok';
end $$;

-- recado na conversa do pedido (os dois lados)
create or replace function public.vis_mensagem(p_token text, p_id bigint, p_texto text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token); v vis_propostas; em text;
begin
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o recado.'; end if;
  select * into v from vis_propostas where id = p_id;
  if v.id is null then raise exception 'Não encontrei esse pedido.'; end if;
  insert into vis_mensagens (proposta_id, quem, lado, texto)
    values (p_id, q->>'nome', case when q->>'tipo' = 'caliman' then 'caliman' else 'equipe' end, left(trim(p_texto), 1000));
  update vis_propostas set atualizado_em = now() where id = p_id;
  if q->>'tipo' = 'caliman' then
    perform public._vis_avisar(v.id, 'dono', null, '[Recado] ' || (q->>'nome') || ' sobre: ' || public._vis_frase(v),
      (q->>'nome') || ' escreveu:' || chr(10) || trim(p_texto) || chr(10) || chr(10) || 'Pedido: ' || public._vis_frase(v));
  else
    perform public._vis_avisar_pessoa(v, 'Recado de ' || (q->>'nome') || ': ' || public._vis_frase(v),
      '💬 ' || (q->>'nome') || ' escreveu: ' || trim(p_texto) || chr(10) || chr(10) || 'Pedido: ' || public._vis_frase(v));
  end if;
  return 'ok';
end $$;

-- ---------------------------------------------------------------- equipe: responder
-- p_status: confirmada | recusada | ciente | feita | pendente (desfazer)
alter table public.vis_propostas add column if not exists alternativa text;   -- "não consigo, mas consigo em ..." 
create or replace function public._vis_responder(p_id bigint, p_status text, p_texto text, p_hora text, p_nome text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := jsonb_build_object('nome', p_nome); v vis_propostas; em text; txt text;
begin
  if p_status not in ('confirmada', 'recusada', 'ciente', 'feita', 'pendente') then raise exception 'Resposta inválida.'; end if;
  if p_status = 'recusada' and coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o motivo de não poder ir.'; end if;
  update vis_propostas set status = p_status, resposta = nullif(left(trim(p_texto), 1000), ''),
    hora_combinada = case when p_status = 'confirmada' then nullif(left(trim(p_hora), 40), '') else hora_combinada end,
    alternativa = case when p_status = 'recusada' then nullif(left(trim(p_hora), 120), '') else null end,
    respondido_por = q->>'nome', respondido_em = now(), atualizado_em = now()
   where id = p_id returning * into v;
  if v.id is null then raise exception 'Não encontrei esse pedido.'; end if;
  txt := case p_status when 'confirmada' then 'Confirmou' || coalesce(' (chega ' || v.hora_combinada || ')', '')
                       when 'recusada' then 'Não vai conseguir nesse horário' when 'ciente' then 'Ciente'
                       when 'feita' then 'Visita feita' else 'Voltou para pendente' end;
  insert into vis_mensagens (proposta_id, quem, lado, texto)
    values (p_id, q->>'nome', 'equipe', txt || coalesce(': ' || v.resposta, '.') || coalesce(chr(10) || '🕒 Consigo: ' || v.alternativa, ''));
  if p_status in ('confirmada', 'recusada', 'ciente') then
    perform public._vis_avisar_pessoa(v,
      (case p_status when 'confirmada' then 'Confirmado: ' when 'ciente' then 'Ciente: ' else 'Não vai dar: ' end) || public._vis_frase(v),
      (case p_status when 'confirmada' then '✅ ' when 'ciente' then '👍 ' else '❌ ' end) || (q->>'nome') || ': ' || txt ||
      coalesce(': ' || v.resposta, '.') || coalesce(chr(10) || '🕒 Consigo: ' || v.alternativa, '') ||
      chr(10) || chr(10) || 'Pedido: ' || public._vis_frase(v));
  end if;
  return 'ok';
end $$;

revoke execute on function public._vis_responder(bigint, text, text, text, text) from public, anon, authenticated;

create or replace function public.vis_responder(p_token text, p_id bigint, p_status text, p_texto text default null,
  p_hora text default null) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe');
begin
  return public._vis_responder(p_id, p_status, p_texto, p_hora, q->>'nome');
end $$;

-- responder pelo botão do e-mail (link com a chave secreta do pedido, sem senha)
create or replace function public.vis_link_ver(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare v vis_propostas;
begin
  select * into v from vis_propostas where chave_resposta = p_chave and length(coalesce(p_chave, '')) >= 32;
  if v.id is null then return json_build_object('erro', 'Link inválido ou pedido apagado.'); end if;
  return (public._vis_json(v, true) - 'chave_resposta' || jsonb_build_object('hoje', public._vis_hoje(),
    'nome_dono', (select nome_dono from vis_config where id = 1), 'locais', (select locais from vis_config where id = 1)))::json;
end $$;

create or replace function public.vis_link_responder(p_chave text, p_status text, p_texto text default null, p_hora text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v vis_propostas;
begin
  if p_status not in ('confirmada', 'recusada', 'ciente', 'feita') then raise exception 'Resposta inválida.'; end if;
  select * into v from vis_propostas where chave_resposta = p_chave and length(coalesce(p_chave, '')) >= 32;
  if v.id is null then raise exception 'Link inválido ou pedido apagado.'; end if;
  if v.status = 'cancelada' then raise exception 'A Caliman cancelou esse pedido.'; end if;
  return public._vis_responder(v.id, p_status, p_texto, p_hora, (select nome_dono from vis_config where id = 1));
end $$;
grant execute on function public.vis_link_ver(text), public.vis_link_responder(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------- remarcar (novo dia / horário / local combinado na conversa)
-- equipe remarca = já fica CONFIRMADO no novo horário e a pessoa recebe no WhatsApp;
-- Caliman remarca = volta para "aguardando" e você recebe no WhatsApp com o link de resposta.
create or replace function public._vis_remarcar(p_id bigint, p_dados jsonb, p_nome text, p_lado text) returns text
language plpgsql security definer set search_path = public as $$
declare v vis_propostas; antes text; d date; hi time; hf time; lc text; obs text;
begin
  select * into v from vis_propostas where id = p_id;
  if v.id is null then raise exception 'Não encontrei esse pedido.'; end if;
  if v.status in ('cancelada', 'feita') then raise exception 'Esse pedido já foi encerrado.'; end if;
  d := nullif(p_dados->>'dia', '')::date;
  if d is null then raise exception 'Escolha o dia.'; end if;
  if d < public._vis_hoje() or d > public._vis_hoje() + 60 then raise exception 'Dia fora do período (de hoje até 60 dias).'; end if;
  hi := nullif(p_dados->>'hora_ini', '')::time;
  hf := nullif(p_dados->>'hora_fim', '')::time;
  if hi is null and hf is null then raise exception 'Informe o horário.'; end if;
  if hi is not null and hf is not null and hf <= hi then raise exception 'O horário final precisa ser depois do inicial.'; end if;
  lc := coalesce(nullif(left(trim(p_dados->>'local'), 60), ''), v.local);
  obs := nullif(left(trim(p_dados->>'recado'), 500), '');
  antes := public._vis_frase(v);
  update vis_propostas set dia = d, hora_ini = hi, hora_fim = hf, local = lc, alternativa = null, hora_combinada = null,
    status = case when p_lado = 'equipe' then 'confirmada' else 'pendente' end,
    resposta = case when p_lado = 'equipe' then obs end,
    respondido_por = case when p_lado = 'equipe' then p_nome end,
    respondido_em = case when p_lado = 'equipe' then now() end,
    atualizado_em = now()
   where id = p_id returning * into v;
  insert into vis_mensagens (proposta_id, quem, lado, texto) values (p_id, p_nome, p_lado,
    '📅 Remarcou para ' || public._vis_frase(v) || case when p_lado = 'equipe' then ' (confirmado)' else '' end || '.' ||
    coalesce(chr(10) || obs, '') || chr(10) || '(antes: ' || antes || ')');
  if p_lado = 'equipe' then
    perform public._vis_avisar_pessoa(v, 'Remarcado e confirmado: ' || public._vis_frase(v),
      '📅 ' || p_nome || ' remarcou e confirmou:' || chr(10) || public._vis_frase(v) || coalesce(chr(10) || obs, '') ||
      chr(10) || chr(10) || '(antes: ' || antes || ')');
  else
    perform public._vis_avisar(v.id, 'dono', null, '[Remarcado] ' || p_nome || ': ' || public._vis_frase(v),
      p_nome || ' remarcou o pedido para:' || chr(10) || chr(10) || public._vis_frase(v) || '. Consegue?' ||
      coalesce(chr(10) || chr(10) || 'Recado: ' || obs, '') || chr(10) || chr(10) || '(antes: ' || antes || ')');
  end if;
  return 'ok';
end $$;
revoke execute on function public._vis_remarcar(bigint, jsonb, text, text) from public, anon, authenticated;

create or replace function public.vis_remarcar(p_token text, p_id bigint, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token); v vis_propostas;
begin
  select * into v from vis_propostas where id = p_id;
  if q->>'tipo' = 'caliman' then
    if v.pessoa_id is distinct from (q->>'pessoa_id')::bigint then raise exception 'Só quem mandou o pedido pode remarcar.'; end if;
    return public._vis_remarcar(p_id, p_dados, q->>'nome', 'caliman');
  end if;
  perform public._vis_exige(p_token, 'equipe');
  return public._vis_remarcar(p_id, p_dados, q->>'nome', 'equipe');
end $$;

create or replace function public.vis_link_remarcar(p_chave text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v vis_propostas;
begin
  select * into v from vis_propostas where chave_resposta = p_chave and length(coalesce(p_chave, '')) >= 32;
  if v.id is null then raise exception 'Link inválido ou pedido apagado.'; end if;
  return public._vis_remarcar(v.id, p_dados, (select nome_dono from vis_config where id = 1), 'equipe');
end $$;
grant execute on function public.vis_remarcar(text, bigint, jsonb), public.vis_link_remarcar(text, jsonb) to anon, authenticated;

-- apagar pedido (só equipe; leva junto recados e avisos da fila)
create or replace function public.vis_apagar(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe');
begin
  delete from vis_propostas where id = p_id;
  return 'ok';
end $$;
grant execute on function public.vis_apagar(text, bigint) to anon, authenticated;

-- ---------------------------------------------------------------- equipe: pessoas e ajustes
drop function if exists public.vis_pessoa_salvar(text, bigint, text, text, text, boolean, text);
create or replace function public.vis_pessoa_salvar(p_token text, p_id bigint, p_nome text, p_celular text,
  p_email text default null, p_ativo boolean default true, p_empresa text default null, p_matricula text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe'); c text := public._vis_cel(p_celular); novo bigint;
        e text := nullif(lower(trim(coalesce(p_email, ''))), ''); m text := nullif(left(trim(coalesce(p_matricula, '')), 30), '');
begin
  if coalesce(trim(p_nome), '') = '' then raise exception 'Preencha o nome.'; end if;
  if length(c) not in (10, 11) then raise exception 'Celular precisa ter DDD + número (10 ou 11 dígitos).'; end if;
  if e is not null and e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  if exists (select 1 from vis_pessoas where celular = c and id is distinct from p_id) then
    raise exception 'Esse celular já está cadastrado.';
  end if;
  if p_id is null then
    insert into vis_pessoas (nome, celular, email, ativo, empresa, matricula)
      values (trim(p_nome), c, e, coalesce(p_ativo, true), coalesce(nullif(trim(p_empresa), ''), 'Caliman'), m) returning id into novo;
  else
    update vis_pessoas set nome = trim(p_nome), celular = c, email = e, ativo = coalesce(p_ativo, true), matricula = m,
      empresa = coalesce(nullif(trim(p_empresa), ''), empresa) where id = p_id returning id into novo;
    if not coalesce(p_ativo, true) then delete from vis_sessoes where pessoa_id = p_id; end if;
  end if;
  perform public._central_log(null, q->>'nome', 'cadastro', 'visitas', 'Acesso de visitas: ' || trim(p_nome));
  return novo;
end $$;

-- importar a lista (nome, matrícula, celular): quem já tem o celular é atualizado, o resto é criado
create or replace function public.vis_pessoas_importar(p_token text, p_linhas jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe'); r jsonb; c text; nv int := 0; at int := 0; er jsonb := '[]'::jsonb; i int := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    i := i + 1;
    c := public._vis_cel(r->>'celular');
    if coalesce(trim(r->>'nome'), '') = '' or length(c) not in (10, 11) then
      er := er || jsonb_build_object('linha', i, 'nome', r->>'nome', 'celular', r->>'celular'); continue;
    end if;
    if exists (select 1 from vis_pessoas where celular = c) then
      update vis_pessoas set nome = left(trim(r->>'nome'), 120),
        matricula = coalesce(nullif(left(trim(coalesce(r->>'matricula', '')), 30), ''), matricula) where celular = c;
      at := at + 1;
    else
      insert into vis_pessoas (nome, celular, matricula) values (left(trim(r->>'nome'), 120), c, nullif(left(trim(coalesce(r->>'matricula', '')), 30), ''));
      nv := nv + 1;
    end if;
  end loop;
  perform public._central_log(null, q->>'nome', 'cadastro', 'visitas', 'Importou lista: ' || nv || ' novos, ' || at || ' atualizados');
  return json_build_object('novos', nv, 'atualizados', at, 'erros', er);
end $$;

create or replace function public.vis_pessoa_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe');
begin
  delete from vis_pessoas where id = p_id;
  return 'ok';
end $$;

create or replace function public.vis_config_salvar(p_token text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe'); w text;
begin
  w := regexp_replace(coalesce(p_dados->>'whatsapp_dono', ''), '\D', '', 'g');
  if w <> '' and length(public._vis_cel(w)) not in (10, 11) then raise exception 'WhatsApp precisa ter DDD + número.'; end if;
  update vis_config set
    nome_dono = coalesce(nullif(trim(p_dados->>'nome_dono'), ''), nome_dono),
    dias_semana = case when p_dados ? 'dias_semana' then coalesce((select array_agg(distinct x::int order by x::int)
                    from jsonb_array_elements_text(p_dados->'dias_semana') x where x ~ '^[0-6]$'), '{}') else dias_semana end,
    whatsapp_dono = nullif(public._vis_cel(w), ''),
    locais = coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(p_dados->'locais') x where trim(x) <> ''), locais),
    agenda = case when jsonb_typeof(p_dados->'agenda') = 'array' then coalesce((
      select jsonb_agg(jsonb_build_object('d', (a->>'d')::int, 'onde', left(trim(a->>'onde'), 40),
               'ini', left(coalesce(a->>'ini', ''), 5), 'fim', left(coalesce(a->>'fim', ''), 5), 'obs', left(trim(coalesce(a->>'obs', '')), 120))
             order by (a->>'d')::int)
      from jsonb_array_elements(p_dados->'agenda') a
      where (a->>'d') ~ '^[0-6]$' and coalesce(trim(a->>'onde'), '') <> ''), '[]'::jsonb) else agenda end
  where id = 1;
  return 'ok';
end $$;

-- esconder / mostrar uma ocorrência para a Caliman (p_oculta null = volta ao automático)
create or replace function public.vis_ocultar_salvar(p_token text, p_id bigint, p_oculta boolean) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._vis_exige(p_token, 'equipe');
begin
  if p_oculta is null then delete from vis_ocultar where ocorrencia_id = p_id;
  else insert into vis_ocultar (ocorrencia_id, oculta, por) values (p_id, p_oculta, q->>'nome')
       on conflict (ocorrencia_id) do update set oculta = excluded.oculta, por = excluded.por, em = now();
  end if;
  return 'ok';
end $$;
grant execute on function public.vis_ocultar_salvar(text, bigint, boolean) to anon, authenticated;

-- ---------------------------------------------------------------- robô de e-mail (mesma chave do quadro de demandas)
create or replace function public.vis_avisos_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  return json_build_object('link', (select link from vis_config where id = 1),
    'avisos', coalesce((select json_agg(json_build_object('id', a.id, 'para', a.para, 'email', a.email,
        'assunto', a.assunto, 'texto', a.texto, 'proposta_id', a.proposta_id,
        'tipo', v.tipo, 'status', v.status, 'chave', case when a.para = 'dono' then v.chave_resposta end) order by a.id)
      from (select * from vis_avisos where enviado_em is null and tentativas < 5 and (para = 'dono' or email is not null)
            order by id limit 20) a
      left join vis_propostas v on v.id = a.proposta_id), '[]'::json));
end $$;

create or replace function public.vis_aviso_marcar(p_chave text, p_id bigint, p_ok boolean, p_erro text default null) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  update vis_avisos set enviado_em = case when p_ok then now() end, tentativas = tentativas + 1,
    erro = case when p_ok then null else left(p_erro, 500) end where id = p_id;
  return 'ok';
end $$;

-- ---------------------------------------------------------------- WhatsApp para você (n8n da TV Box + Evolution)
-- O fluxo "Visitas — WhatsApp" (a cada 1 min) pega aqui os avisos para você e manda pelo chip do robô
-- para o número em Ajustes (vis_config.whatsapp_dono). O e-mail continua indo junto (reserva).
alter table public.vis_avisos add column if not exists whats_em timestamptz;
alter table public.vis_avisos add column if not exists whats_tentativas int not null default 0;
alter table public.vis_avisos add column if not exists whats_erro text;

create or replace function public.vis_whats_pendentes(p_limite integer default 5) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c vis_config;
begin
  select * into c from vis_config where id = 1;
  return jsonb_build_object('avisos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'numero', '55' || x.numero, 'texto', x.txt) order by x.id)
    from (select a.id, case when a.para = 'dono' then c.whatsapp_dono else a.numero end as numero,
      '🚌 *Visitas aos carros*' || chr(10) || chr(10) || a.texto ||
      case when a.para = 'dono' and v.status = 'pendente' and v.chave_resposta is not null then
             chr(10) || chr(10) || '👉 Responder (' || case when v.tipo = 'visita' then 'consigo ir / não consigo' else 'ciente / vou passar lá' end || '):' ||
             chr(10) || c.link || '?r=' || v.chave_resposta
           else chr(10) || chr(10) || 'Abrir: ' || c.link || coalesce('?p=' || a.proposta_id, '') end as txt
      from vis_avisos a left join vis_propostas v on v.id = a.proposta_id
      where a.whats_em is null and a.whats_tentativas < 3 and a.criado_em > now() - interval '6 hours'
        and ((a.para = 'dono' and c.whatsapp_dono is not null) or (a.para = 'pessoa' and a.numero is not null))
      order by a.id limit greatest(1, least(coalesce(p_limite, 5), 20))) x), '[]'::jsonb));
end $$;

create or replace function public.vis_whats_marcar(p_id bigint, p_ok boolean, p_erro text default null) returns text
language sql security definer set search_path = public as $$
  update vis_avisos set whats_em = case when p_ok then now() end, whats_tentativas = whats_tentativas + 1,
    whats_erro = case when p_ok then null else left(p_erro, 500) end where id = p_id;
  select 'ok';
$$;
revoke all on function public.vis_whats_pendentes(integer), public.vis_whats_marcar(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.vis_whats_pendentes(integer), public.vis_whats_marcar(bigint, boolean, text) to service_role;

-- ---------------------------------------------------------------- permissões
grant execute on function public.vis_entrar(text), public.vis_sessao(text), public.vis_sair(text), public.vis_painel(text),
  public.vis_propor(text, jsonb), public.vis_cancelar(text, bigint), public.vis_mensagem(text, bigint, text),
  public.vis_responder(text, bigint, text, text, text),
  public.vis_pessoa_salvar(text, bigint, text, text, text, boolean, text, text), public.vis_pessoa_remover(text, bigint),
  public.vis_pessoas_importar(text, jsonb),
  public.vis_config_salvar(text, jsonb), public.vis_avisos_pendentes(text), public.vis_aviso_marcar(text, bigint, boolean, text)
  to anon, authenticated;

select 'Visitas prontas' as resultado, (select count(*) from public.vis_pessoas) as pessoas_caliman,
       (select count(*) from public.vis_propostas) as pedidos;
