-- =====================================================================
-- EVENTOS (página gestao-integrada.github.io/eventos/)
-- Um lugar só para os eventos da frota e para QUEM recebe cada um e POR ONDE:
--   - Destinatários: nome, função, matrícula, empresa, e-mail, WhatsApp;
--   - Quem recebe o quê: por pessoa e por tipo de evento, e-mail e/ou WhatsApp,
--     opcionalmente só dos carros de certas empresas;
--   - Tipos de evento: liga/desliga, se pede justificativa, se exige evidência, prazo, motivos;
--   - Lista única de eventos com a justificativa e as evidências, e o histórico de envios.
-- Evento nativo nesta versão: PONTUALIDADE nas cercas de turno do BI (adiantado / atrasado).
-- A pessoa recebe um link (sem senha) /eventos/j/?t=..., escolhe o motivo, justifica e anexa a
-- evidência; você aceita ou devolve para refazer no painel.
-- Roteador, passageiro fora de rota e aberturas erradas aparecem na lista (lidos das tabelas deles);
-- o envio deles continua pelos fluxos atuais (fase 2 passa para cá).
-- Demandas das vistorias NÃO entram aqui (continuam no quadro de Demandas).
--
-- Envio: e-mail pelo robô Apps Script do quadro de Demandas (arquivo sql/eventos-aviso.gs, mesma CHAVE);
--        WhatsApp pelo n8n da TV Box + Evolution (fluxo sql/eventos-whatsapp.json).
-- Quem entra: senha pessoal da Central (admin, ou painel "eventos" marcado em Ver/Editar) ou senha de gestores.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo.
-- Depende de: central-acessos.sql, lotacao.sql (viagens), solicitacoes.sql (sol_config.chave_robo,
-- sol_sessoes_gestor), bi.sql (cercas e _bi_horarios), schema do Monitor (samples).
-- =====================================================================

-- ---------------------------------------------------------------- tabelas
create table if not exists public.ev_config (
  id            int primary key default 1 check (id = 1),
  link          text not null default 'https://gestao-integrada.github.io/eventos/j/',
  dias_link     int not null default 30,      -- quanto tempo o link de justificativa vale
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
insert into public.ev_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.ev_tipos (
  codigo             text primary key,
  nome               text not null,
  descricao          text,
  origem             text not null default 'nativo' check (origem in ('nativo', 'externo')),  -- externo = enviado pelo fluxo antigo
  ativo              boolean not null default true,
  pede_justificativa boolean not null default true,
  exige_evidencia    boolean not null default true,
  prazo_horas        int not null default 48,
  envio              text not null default 'diario' check (envio in ('na_hora', 'diario')),
  hora_envio         int not null default 8,       -- hora de Belém do resumo diário
  motivos            text[] not null default '{}',
  opcoes             jsonb not null default '{}'::jsonb,
  ordem              int not null default 100,
  ultimo_envio       date
);
insert into public.ev_tipos (codigo, nome, descricao, origem, ativo, pede_justificativa, exige_evidencia, prazo_horas, envio, hora_envio, motivos, opcoes, ordem) values
  ('pontualidade', 'Pontualidade nas cercas', 'Ônibus que chegou adiantado ou atrasado na cerca do turno (IDA) ou saiu fora do horário (VOLTA), medido pelo BI.',
   'nativo', true, true, true, 48, 'diario', 8,
   '{Trânsito / via interditada,Problema mecânico,Saída atrasada da garagem,Atraso de passageiro,Clima / chuva,Desvio de rota autorizado,Ordem da supervisão,Horário da rota mudou,Erro de GPS / horário,Outro}',
   '{"tipos": ["adiantado", "atrasado"], "so_monitor": false, "dias_atras": 2}'::jsonb, 10),
  ('roteador', 'Uso de roteador', 'Celular do ônibus usado como roteador (hotspot). Envio pelo alerta atual do roteador.',
   'externo', true, true, true, 72, 'na_hora', 8, '{}', '{}'::jsonb, 20),
  ('fora_rota', 'Passageiro fora de rota', 'Passageiro embarcando em rota diferente da cadastrada. Envio pela lotação (gestor da pessoa).',
   'externo', true, true, false, 72, 'diario', 8, '{}', '{}'::jsonb, 30),
  ('abertura', 'Abertura errada de viagem', 'Viagem aberta errado no app (sentido, rota). Vai como demanda para a Caliman.',
   'externo', true, true, true, 72, 'diario', 9, '{}', '{}'::jsonb, 40)
on conflict (codigo) do nothing;

create table if not exists public.ev_pessoas (
  id            bigserial primary key,
  nome          text not null,
  funcao        text,
  matricula     text,
  empresa       text,
  email         text,
  whatsapp      text,          -- só dígitos, com 55 + DDD + 9
  ativo         boolean not null default true,
  obs           text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);

create table if not exists public.ev_inscricoes (
  pessoa_id  bigint not null references public.ev_pessoas(id) on delete cascade,
  tipo       text not null references public.ev_tipos(codigo) on delete cascade,
  email      boolean not null default false,
  whatsapp   boolean not null default false,
  empresas   text[] not null default '{}',   -- vazio = todas; senão só eventos de carros dessas empresas
  primary key (pessoa_id, tipo)
);

create table if not exists public.ev_eventos (
  id             bigserial primary key,
  tipo           text not null references public.ev_tipos(codigo),
  chave          text not null,
  data           date not null,
  ocorreu_em     timestamptz,
  empresa        text,
  frota          text,
  linha          text,
  titulo         text not null,
  detalhe        jsonb not null default '{}'::jsonb,
  situacao       text not null default 'aguardando'
                 check (situacao in ('aguardando', 'justificado', 'aceito', 'refazer', 'encerrado')),
  rodada         int not null default 1,          -- sobe quando é devolvido para refazer (reenvia)
  prazo          timestamptz,
  motivo         text,
  justificativa  text,
  respondido_por text,
  respondido_em  timestamptz,
  analise_por    text,
  analise_em     timestamptz,
  analise_obs    text,
  criado_em      timestamptz not null default now(),
  unique (tipo, chave)
);
create index if not exists ev_eventos_data on public.ev_eventos (data desc);
create index if not exists ev_eventos_pend on public.ev_eventos (tipo, situacao) where situacao in ('aguardando', 'refazer');

create table if not exists public.ev_evidencias (
  id          bigserial primary key,
  evento_id   bigint not null references public.ev_eventos(id) on delete cascade,
  nome        text not null,
  tipo        text,
  tamanho     int not null,
  dados       bytea not null,
  enviado_por text,
  enviado_em  timestamptz not null default now()
);
create index if not exists ev_evidencias_ev on public.ev_evidencias (evento_id);

create table if not exists public.ev_historico (
  id        bigserial primary key,
  evento_id bigint not null references public.ev_eventos(id) on delete cascade,
  ts        timestamptz not null default now(),
  quem      text,
  acao      text not null,
  texto     text
);
create index if not exists ev_historico_ev on public.ev_historico (evento_id, ts);

-- fila de envio: 1 linha por pessoa + canal + rodada de envio (pode levar vários eventos)
create table if not exists public.ev_envios (
  id          bigserial primary key,
  tipo        text not null references public.ev_tipos(codigo) on delete cascade,
  pessoa_id   bigint references public.ev_pessoas(id) on delete set null,
  nome        text,
  canal       text not null check (canal in ('email', 'whatsapp')),
  destino     text not null,
  token       text not null unique,
  assunto     text,
  texto       text,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  enviado_em  timestamptz,
  tentativas  int not null default 0,
  erro        text,
  aberto_em   timestamptz
);
create index if not exists ev_envios_fila on public.ev_envios (canal, id) where enviado_em is null;
create table if not exists public.ev_envio_itens (
  envio_id  bigint not null references public.ev_envios(id) on delete cascade,
  evento_id bigint not null references public.ev_eventos(id) on delete cascade,
  rodada    int not null,
  primary key (envio_id, evento_id)
);
create index if not exists ev_envio_itens_ev on public.ev_envio_itens (evento_id, rodada);

alter table public.ev_config      enable row level security;   -- sem policy: só pelas funções abaixo
alter table public.ev_tipos       enable row level security;
alter table public.ev_pessoas     enable row level security;   -- dado pessoal (e-mail, telefone)
alter table public.ev_inscricoes  enable row level security;
alter table public.ev_eventos     enable row level security;
alter table public.ev_evidencias  enable row level security;
alter table public.ev_historico   enable row level security;
alter table public.ev_envios      enable row level security;
alter table public.ev_envio_itens enable row level security;
revoke all on public.ev_config, public.ev_tipos, public.ev_pessoas, public.ev_inscricoes, public.ev_eventos,
  public.ev_evidencias, public.ev_historico, public.ev_envios, public.ev_envio_itens from anon, authenticated;

-- ---------------------------------------------------------------- utilidades
create or replace function public._ev_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Belem')::date $$;

create or replace function public._ev_fone(t text) returns text
language sql immutable as $$
  select case
    when d ~ '^55\d{2}9\d{8}$' then d
    when d ~ '^\d{2}9\d{8}$' then '55' || d
    else null end
  from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as d) x;
$$;

create or replace function public._ev_emp(e text) returns text
language sql immutable as $$ select nullif(upper(trim(regexp_replace(coalesce(e, ''), '\s+', ' ', 'g'))), '') $$;

-- quem está usando o painel (token da Central tfs_ ou senha de gestores tfg_)
create or replace function public._ev_quem(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a central_acessos;
begin
  if p_token like 'tfs_%' then
    select * into a from public._central_pessoa(p_token);
    if a.id is not null and public._central_pode(a, 'eventos', 'ver') then
      update central_sessoes set ultimo_uso = now() where token = p_token;
      return jsonb_build_object('nome', a.nome, 'acesso_id', a.id, 'admin', a.admin,
                                'edita', public._central_pode(a, 'eventos', 'editar'));
    end if;
  elsif p_token like 'tfg_%' then
    if exists (select 1 from sol_sessoes_gestor where token = p_token and expira_em > now()) then
      return jsonb_build_object('nome', 'Senha de gestores', 'acesso_id', null, 'admin', true, 'edita', true);
    end if;
  end if;
  return null;
end $$;

create or replace function public._ev_exige(p_token text, p_editar boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_quem(p_token);
begin
  if q is null then raise exception 'sessao'; end if;
  if p_editar and not (q->>'edita')::boolean then raise exception 'Você pode ver os eventos, mas não alterar.'; end if;
  return q;
end $$;

create or replace function public._ev_log(q jsonb, p_resumo text, p_tabela text default null, p_registro text default null) returns void
language sql security definer set search_path = public as $$
  select public._central_log((q->>'acesso_id')::bigint, q->>'nome', 'editou', 'eventos', p_resumo, p_tabela, p_registro);
$$;

revoke execute on function public._ev_quem(text), public._ev_exige(text, boolean), public._ev_log(jsonb, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- entrar / sessão / sair
create or replace function public.ev_entrar(p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'eventos'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is not null then
    if not public._central_pode(a, 'eventos', 'ver') then
      return json_build_object('erro', 'Sua senha não tem acesso aos Eventos. Peça para liberar o painel Eventos na Gestão de acessos.');
    end if;
    tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
    insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
    perform public._central_log(a.id, a.nome, 'entrou', 'eventos', 'Entrou nos Eventos');
    return (jsonb_build_object('token', tk) || public._ev_quem(tk))::json;
  end if;
  if exists (select 1 from lotacao_admin where id = 1 and senha_hash = crypt(trim(p_senha), senha_hash)) then
    tk := 'tfg_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes_gestor (token, expira_em) values (tk, now() + interval '30 days');
    perform public._central_log(null, 'Senha de gestores', 'entrou', 'eventos', 'Entrou nos Eventos');
    return (jsonb_build_object('token', tk) || public._ev_quem(tk))::json;
  end if;
  perform public._central_log(null, null, 'senha_errada', 'eventos', 'Senha errada nos Eventos');
  return json_build_object('erro', 'Senha não encontrada.');
end $$;

create or replace function public.ev_sessao(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_quem(p_token);
begin
  if q is null then return json_build_object('erro', 'sessao'); end if;
  return q::json;
end $$;

create or replace function public.ev_sair(p_token text) returns text
language plpgsql security definer set search_path = public as $$
begin
  delete from sol_sessoes_gestor where token = p_token and p_token like 'tfg_%';
  return 'ok';
end $$;

-- ---------------------------------------------------------------- PONTUALIDADE: gerar eventos a partir do BI
-- Para cada dia (hoje e os anteriores em opcoes.dias_atras): processa as cercas no BI (se ainda não
-- processou depois do fim do dia) e grava 1 evento por viagem adiantada/atrasada.
-- Hoje: só as viagens cujo horário previsto já passou há mais de 2 h (para não julgar viagem em andamento).
create or replace function public._ev_gerar_pontualidade() returns int
language plpgsql security definer set search_path = public as $$
declare t ev_tipos; d date; cs bigint[]; n int := 0; k int; hoje date := _ev_hoje();
  st text[]; so_mon boolean;
begin
  select * into t from ev_tipos where codigo = 'pontualidade';
  if t.codigo is null or not t.ativo then return 0; end if;
  if to_regprocedure('public._bi_horarios(date,date)') is null then return 0; end if;
  st := coalesce(array(select jsonb_array_elements_text(t.opcoes->'tipos')), '{adiantado,atrasado}');
  if cardinality(st) = 0 then st := '{adiantado,atrasado}'; end if;
  so_mon := coalesce((t.opcoes->>'so_monitor')::boolean, false);
  for d in select x::date from generate_series(hoje - greatest(0, least(coalesce((t.opcoes->>'dias_atras')::int, 2), 7)), hoje, interval '1 day') x loop
    -- cercas de turno ainda não processadas depois de o dia acabar (ou hoje, a cada 30 min)
    select array_agg(c.id order by c.id) into cs from bi_cercas c
      left join bi_cerca_dias k on k.cerca_id = c.id and k.dia = d
      where c.ativo and c.finalidade = 'turno'
        and (k.dia is null
             or (d < hoje and k.processado_em < ((d + 1)::timestamp at time zone 'America/Belem') + interval '10 minutes')
             or (d = hoje and k.processado_em < now() - interval '30 minutes'));
    if cs is not null then perform _bi_processar_dia(d, cs); end if;
    insert into ev_eventos (tipo, chave, data, ocorreu_em, empresa, frota, linha, titulo, detalhe, prazo)
    select 'pontualidade',
           h.data || '|' || h.cerca || '|' || h.regra || '|' || coalesce(h.frota, '') || '|' || h.tipo,
           h.data,
           (h.data + h.hora_real::time)::timestamp at time zone 'America/Belem',
           _ev_emp(vv.empresa), h.frota, h.linha,
           'Carro ' || coalesce(h.frota, '?') || ' · ' || h.linha || ' (' || h.tipo || ') · ' ||
             case when h.tipo = 'IDA' then 'chegou ' else 'saiu ' end || h.hora_real || ' em vez de ' || h.prevista ||
             ' · ' || abs(h.dif) || ' min ' || case when h.status = 'adiantado' then 'adiantado' else 'atrasado' end,
           jsonb_build_object('cerca', h.cerca, 'regra', h.regra, 'tipo', h.tipo, 'tipolinha', h.tipolinha, 'motorista', h.motorista,
             'ocupacao', h.ocupacao, 'prevista', h.prevista, 'tol_antes', h.tol_antes, 'tol_depois', h.tol_depois,
             'hora_real', h.hora_real, 'origem', h.origem, 'dif', h.dif, 'status', h.status, 'monitor', h.monitor,
             'monitor_gap', h.monitor_gap, 'tfleet', h.tfleet, 'tem_monitor', h.tem_monitor),
           now() + make_interval(hours => t.prazo_horas)
    from _bi_horarios(d, d) h
    left join lateral (select to_jsonb(v)->>'empresa' as empresa from viagens v
                       where v.data_local = h.data and v.frota = h.frota and v.linha = h.linha and upper(trim(v.tipo)) = h.tipo
                       order by v.coletado_em desc nulls last limit 1) vv on true
    where h.status = any (st) and (not so_mon or h.origem = 'Monitor') and h.hora_real ~ '^\d{1,2}:\d{2}'
      and (d < hoje or ((d + h.prevista::time)::timestamp at time zone 'America/Belem') < now() - interval '2 hours')
    on conflict (tipo, chave) do nothing;
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  insert into ev_historico (evento_id, quem, acao, texto)
  select id, 'Robô', 'criado', 'Evento detectado pelo BI' from ev_eventos e
   where e.tipo = 'pontualidade' and e.criado_em > now() - interval '1 minute'
     and not exists (select 1 from ev_historico h where h.evento_id = e.id);
  return n;
end $$;
revoke execute on function public._ev_gerar_pontualidade() from public, anon, authenticated;

-- ---------------------------------------------------------------- montar os envios (fila)
-- Para cada tipo NATIVO ativo: na hora (a cada rodada) ou 1x por dia na hora_envio.
-- Cada pessoa inscrita recebe, por canal marcado, 1 mensagem com os eventos pendentes (aguardando/refazer)
-- que ainda não recebeu nessa rodada, filtrados pelas empresas da inscrição.
create or replace function public._ev_montar_envios(p_forcar boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare t ev_tipos; i record; c text; dest text; ids bigint[]; n int := 0; eid bigint; tk text;
  cfg ev_config; hoje date := _ev_hoje(); hora int := extract(hour from now() at time zone 'America/Belem');
  lista text; qtd int;
begin
  select * into cfg from ev_config where id = 1;
  for t in select * from ev_tipos where origem = 'nativo' and ativo loop
    if not p_forcar and t.envio = 'diario' and (hora < t.hora_envio or t.ultimo_envio = hoje) then continue; end if;
    for i in select p.*, s.email as q_email, s.whatsapp as q_whats, s.empresas
               from ev_inscricoes s join ev_pessoas p on p.id = s.pessoa_id
              where s.tipo = t.codigo and p.ativo and (s.email or s.whatsapp) loop
      foreach c in array array['email', 'whatsapp'] loop
        if c = 'email' and not (i.q_email and coalesce(trim(i.email), '') like '%@%') then continue; end if;
        if c = 'whatsapp' and not (i.q_whats and _ev_fone(i.whatsapp) is not null) then continue; end if;
        dest := case when c = 'email' then lower(trim(i.email)) else _ev_fone(i.whatsapp) end;
        select array_agg(e.id order by e.data, e.ocorreu_em) into ids from ev_eventos e
         where e.tipo = t.codigo and e.situacao in ('aguardando', 'refazer')
           and e.criado_em > now() - interval '15 days'
           and (cardinality(i.empresas) = 0 or e.empresa = any (i.empresas))
           and not exists (select 1 from ev_envio_itens x join ev_envios v on v.id = x.envio_id
                           where x.evento_id = e.id and x.rodada = e.rodada and v.pessoa_id = i.id and v.canal = c);
        if ids is null then continue; end if;
        qtd := cardinality(ids);
        select string_agg('• ' || to_char(e.data, 'DD/MM') || ' ' || e.titulo ||
                 case when e.situacao = 'refazer' then ' (devolvido: ' || coalesce(e.analise_obs, 'refazer') || ')' else '' end, chr(10)
                 order by e.data, e.ocorreu_em)
          into lista from (select * from ev_eventos where id = any (ids) order by data, ocorreu_em limit 15) e;
        if qtd > 15 then lista := lista || chr(10) || '… e mais ' || (qtd - 15) || '.'; end if;
        tk := 'tfe_' || encode(gen_random_bytes(18), 'hex');
        insert into ev_envios (tipo, pessoa_id, nome, canal, destino, token, assunto, texto, expira_em)
        values (t.codigo, i.id, i.nome, c, dest, tk,
                t.nome || ': ' || qtd || ' evento(s) para justificar',
                'Olá, ' || split_part(i.nome, ' ', 1) || '.' || chr(10) || chr(10) ||
                qtd || ' evento(s) de ' || lower(t.nome) || ' precisam de justificativa' ||
                case when t.exige_evidencia then ' com evidência (foto, print ou documento)' else '' end ||
                ' até ' || to_char((now() + make_interval(hours => t.prazo_horas)) at time zone 'America/Belem', 'DD/MM HH24:MI') || ':' ||
                chr(10) || chr(10) || lista,
                now() + make_interval(days => cfg.dias_link))
        returning id into eid;
        insert into ev_envio_itens (envio_id, evento_id, rodada)
        select eid, e.id, e.rodada from ev_eventos e where e.id = any (ids);
        n := n + 1;
      end loop;
    end loop;
    if t.envio = 'diario' then update ev_tipos set ultimo_envio = hoje where codigo = t.codigo; end if;
  end loop;
  return n;
end $$;
revoke execute on function public._ev_montar_envios(boolean) from public, anon, authenticated;

-- rodada completa (pg_cron a cada 15 min): gera eventos e monta a fila
create or replace function public.ev_rodar(p_forcar boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare g int := 0; m int;
begin
  begin
    g := _ev_gerar_pontualidade();
  exception when others then
    raise warning 'eventos: pontualidade falhou: %', sqlerrm;
  end;
  m := _ev_montar_envios(p_forcar);
  return g || ' evento(s) novo(s); ' || m || ' mensagem(ns) na fila.';
end $$;
revoke execute on function public.ev_rodar(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- painel: dados
-- eventos de todas as origens no período (nativos + roteador + fora de rota + aberturas), já no mesmo formato
create or replace function public._ev_unificados(p_de date, p_ate date) returns setof jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  select jsonb_build_object('id', e.id, 'origem', 'nativo', 'tipo', e.tipo, 'data', e.data,
      'hora', to_char(e.ocorreu_em at time zone 'America/Belem', 'HH24:MI'), 'empresa', e.empresa, 'frota', e.frota, 'linha', e.linha,
      'titulo', e.titulo, 'detalhe', e.detalhe,
      'situacao', case when e.situacao in ('aguardando', 'refazer') and e.prazo < now() then 'vencido' else e.situacao end,
      'situacao_real', e.situacao, 'prazo', e.prazo, 'motivo', e.motivo, 'justificativa', e.justificativa,
      'respondido_por', e.respondido_por, 'respondido_em', e.respondido_em,
      'analise_por', e.analise_por, 'analise_em', e.analise_em, 'analise_obs', e.analise_obs,
      'evid', (select count(*) from ev_evidencias v where v.evento_id = e.id),
      'enviados', (select count(*) from ev_envio_itens x join ev_envios v on v.id = x.envio_id
                   where x.evento_id = e.id and v.enviado_em is not null))
  from ev_eventos e where e.data between p_de and p_ate;

  if to_regclass('public.roteador_tratativas') is not null and to_regclass('public.events') is not null then
    return query execute $q$
      select jsonb_build_object('id', 'r' || t.event_id, 'origem', 'externo', 'tipo', 'roteador',
        'data', (e.ts at time zone 'America/Belem')::date, 'hora', to_char(e.ts at time zone 'America/Belem', 'HH24:MI'),
        'frota', coalesce(nullif(e.device_name, ''), e.device_id),
        'titulo', 'Roteador usado no carro ' || coalesce(nullif(e.device_name, ''), e.device_id) ||
                  coalesce(' · ' || round(nullif(e.detail->>'mb_usados', '')::numeric, 1) || ' MB', ''),
        'situacao', case when t.tratado_em is not null then 'justificado'
                         when t.criado_em < now() - interval '72 hours' then 'vencido' else 'aguardando' end,
        'motivo', t.tratativa, 'justificativa', t.observacao, 'respondido_por', t.tratado_por, 'respondido_em', t.tratado_em,
        'enviados', 1)
      from roteador_tratativas t join events e on e.id = t.event_id
      where (e.ts at time zone 'America/Belem')::date between $1 and $2 $q$ using p_de, p_ate;
  end if;

  if to_regclass('public.consultas') is not null then
    return query execute $q$
      select jsonb_build_object('id', 'c' || c.id, 'origem', 'externo', 'tipo', 'fora_rota',
        'data', (c.criado_em at time zone 'America/Belem')::date, 'hora', to_char(c.criado_em at time zone 'America/Belem', 'HH24:MI'),
        'linha', c.linha_usada,
        'titulo', coalesce(c.nome, c.matricula, 'Passageiro') || ' · usou ' || coalesce(c.linha_usada, '?') ||
                  ' (cadastro: ' || coalesce(c.linha_cadastro, 'sem linha') || ') · ' || coalesce(c.dias, 0) || ' dia(s)',
        'situacao', case when c.respondido_em is not null then 'justificado'
                         when c.criado_em < now() - interval '72 hours' then 'vencido' else 'aguardando' end,
        'motivo', c.resposta, 'justificativa', c.comentario,
        'respondido_por', to_jsonb(c)->>'respondido_por', 'respondido_em', c.respondido_em,
        'para', c.enviado_para, 'enviados', case when c.enviado_para is not null then 1 else 0 end)
      from consultas c where (c.criado_em at time zone 'America/Belem')::date between $1 and $2 $q$ using p_de, p_ate;
  end if;

  if to_regclass('public.abt_casos') is not null then
    return query execute $q$
      select jsonb_build_object('id', 'a' || a.viagem_id || '|' || a.regra, 'origem', 'externo', 'tipo', 'abertura',
        'data', a.data_local, 'hora', to_char(a.hora, 'HH24:MI'), 'frota', a.frota, 'linha', a.linha,
        'titulo', 'Carro ' || coalesce(a.frota, '?') || ' · ' || coalesce(a.linha, '') || ' ' || coalesce(a.tipo, '') || ' · ' || coalesce(a.problema, a.regra),
        'situacao', case when a.situacao = 'aberto' then 'aguardando' when a.situacao = 'falso' then 'encerrado' else 'justificado' end,
        'motivo', a.situacao, 'justificativa', a.obs, 'respondido_por', a.marcado_por, 'respondido_em', a.marcado_em,
        'enviados', case when a.avisado_em is not null then 1 else 0 end)
      from abt_casos a where a.data_local between $1 and $2 $q$ using p_de, p_ate;
  end if;
end $$;
revoke execute on function public._ev_unificados(date, date) from public, anon, authenticated;

create or replace function public.ev_painel(p_token text, p_de date default null, p_ate date default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token); de date := coalesce(p_de, _ev_hoje() - 6); ate date := coalesce(p_ate, _ev_hoje());
begin
  if ate - de > 92 then raise exception 'Escolha um período de até 3 meses.'; end if;
  return json_build_object(
    'quem', q, 'de', de, 'ate', ate, 'hoje', _ev_hoje(),
    'eventos', (select coalesce(json_agg(x order by x->>'data' desc, x->>'hora' desc nulls last), '[]'::json) from _ev_unificados(de, ate) x),
    'tipos', (select coalesce(json_agg(to_jsonb(t) order by t.ordem, t.codigo), '[]'::json) from ev_tipos t),
    'pessoas', (select coalesce(json_agg(to_jsonb(p) order by p.ativo desc, p.nome), '[]'::json) from ev_pessoas p),
    'inscricoes', (select coalesce(json_agg(to_jsonb(s)), '[]'::json) from ev_inscricoes s),
    'empresas', (select coalesce(json_agg(e order by e), '[]'::json) from (
        select distinct _ev_emp(to_jsonb(v)->>'empresa') as e from viagens v where v.data_local > _ev_hoje() - 60
        union select _ev_emp(empresa) from ev_pessoas) z where e is not null),
    'config', (select to_jsonb(c) from ev_config c where id = 1),
    'fila', json_build_object(
       'pendentes', (select count(*) from ev_envios where enviado_em is null and tentativas < 5 and expira_em > now()),
       'erros', (select count(*) from ev_envios where enviado_em is null and tentativas >= 1),
       'ultimo_email', (select max(enviado_em) from ev_envios where canal = 'email'),
       'ultimo_whats', (select max(enviado_em) from ev_envios where canal = 'whatsapp')),
    'bi_ok', to_regprocedure('public._bi_horarios(date,date)') is not null,
    'cercas_turno', (select count(*) from bi_cercas where ativo and finalidade = 'turno'));
end $$;

-- detalhe de 1 evento nativo: histórico, evidências, envios
create or replace function public.ev_detalhe(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token);
begin
  return (select json_build_object(
    'evento', to_jsonb(e),
    'evid', (select coalesce(json_agg(json_build_object('id', v.id, 'nome', v.nome, 'tipo', v.tipo, 'tamanho', v.tamanho,
               'por', v.enviado_por, 'em', v.enviado_em) order by v.id), '[]'::json) from ev_evidencias v where v.evento_id = e.id),
    'historico', (select coalesce(json_agg(json_build_object('ts', h.ts, 'quem', h.quem, 'acao', h.acao, 'texto', h.texto) order by h.ts), '[]'::json)
               from ev_historico h where h.evento_id = e.id),
    'envios', (select coalesce(json_agg(json_build_object('nome', v.nome, 'canal', v.canal, 'destino', v.destino, 'criado_em', v.criado_em,
               'enviado_em', v.enviado_em, 'erro', v.erro, 'aberto_em', v.aberto_em, 'rodada', x.rodada) order by v.id), '[]'::json)
               from ev_envio_itens x join ev_envios v on v.id = x.envio_id where x.evento_id = e.id))
    from ev_eventos e where e.id = p_id);
end $$;

-- aceitar / devolver para refazer / encerrar sem justificativa / reabrir
create or replace function public.ev_analisar(p_token text, p_id bigint, p_acao text, p_obs text default null) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true); e ev_eventos;
begin
  select * into e from ev_eventos where id = p_id;
  if e.id is null then raise exception 'Evento não encontrado.'; end if;
  if p_acao not in ('aceito', 'refazer', 'encerrado', 'aguardando') then raise exception 'Ação inválida.'; end if;
  if p_acao = 'refazer' and length(trim(coalesce(p_obs, ''))) < 5 then raise exception 'Diga o que falta (vai na mensagem para a empresa).'; end if;
  update ev_eventos set situacao = p_acao, analise_por = q->>'nome', analise_em = now(), analise_obs = nullif(trim(coalesce(p_obs, '')), ''),
    rodada = rodada + case when p_acao in ('refazer', 'aguardando') and situacao not in ('aguardando', 'refazer') then 1 else 0 end,
    prazo = case when p_acao in ('refazer', 'aguardando') then now() + make_interval(hours => (select prazo_horas from ev_tipos where codigo = e.tipo)) else prazo end
   where id = p_id;
  insert into ev_historico (evento_id, quem, acao, texto) values (p_id, q->>'nome',
    case p_acao when 'aceito' then 'aceito' when 'refazer' then 'devolvido' when 'encerrado' then 'encerrado' else 'reaberto' end,
    nullif(trim(coalesce(p_obs, '')), ''));
  perform _ev_log(q, 'Evento ' || p_id || ': ' || p_acao, 'ev_eventos', p_id::text);
  return 'ok';
end $$;

-- ---------------------------------------------------------------- painel: cadastro
create or replace function public.ev_pessoa_salvar(p_token text, p_dados jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true); v_id bigint := nullif(p_dados->>'id', '')::bigint;
  em text := nullif(lower(trim(p_dados->>'email')), ''); wz text := nullif(trim(p_dados->>'whatsapp'), '');
begin
  if length(trim(coalesce(p_dados->>'nome', ''))) < 3 then raise exception 'Escreva o nome.'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido: %', em; end if;
  if wz is not null and _ev_fone(wz) is null then raise exception 'WhatsApp inválido: use DDD + número de celular (ex.: 91 98888-7777).'; end if;
  if v_id is null then
    insert into ev_pessoas (nome, funcao, matricula, empresa, email, whatsapp, ativo, obs, atualizado_por)
    values (trim(p_dados->>'nome'), nullif(trim(p_dados->>'funcao'), ''), nullif(trim(p_dados->>'matricula'), ''),
            _ev_emp(p_dados->>'empresa'), em, _ev_fone(wz), coalesce((p_dados->>'ativo')::boolean, true),
            nullif(trim(p_dados->>'obs'), ''), q->>'nome')
    returning id into v_id;
    perform _ev_log(q, 'Cadastrou destinatário ' || trim(p_dados->>'nome'), 'ev_pessoas', v_id::text);
  else
    update ev_pessoas set nome = trim(p_dados->>'nome'), funcao = nullif(trim(p_dados->>'funcao'), ''),
      matricula = nullif(trim(p_dados->>'matricula'), ''), empresa = _ev_emp(p_dados->>'empresa'), email = em,
      whatsapp = _ev_fone(wz), ativo = coalesce((p_dados->>'ativo')::boolean, ativo), obs = nullif(trim(p_dados->>'obs'), ''),
      atualizado_em = now(), atualizado_por = q->>'nome'
     where id = v_id;
    if not found then raise exception 'Destinatário não encontrado.'; end if;
    perform _ev_log(q, 'Editou destinatário ' || trim(p_dados->>'nome'), 'ev_pessoas', v_id::text);
  end if;
  return v_id;
end $$;

create or replace function public.ev_pessoa_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true); n text;
begin
  delete from ev_pessoas where id = p_id returning nome into n;
  if n is null then raise exception 'Destinatário não encontrado.'; end if;
  perform _ev_log(q, 'Removeu destinatário ' || n, 'ev_pessoas', p_id::text);
  return 'ok';
end $$;

-- traz os contatos já cadastrados na lotação (gestores por empresa) sem repetir e-mail
create or replace function public.ev_importar_gestores(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true); n int := 0;
begin
  if to_regclass('public.gestores_empresa_contatos') is null then return json_build_object('importados', 0); end if;
  execute $q$
    insert into ev_pessoas (nome, funcao, empresa, email, whatsapp, atualizado_por, obs)
    select coalesce(nullif(trim(g.nome), ''), g.email), g.cargo, public._ev_emp(coalesce(g.empresa_txt, g.empresa)), lower(trim(g.email)),
           public._ev_fone(to_jsonb(g)->>'telefone'), $1, 'Importado dos gestores da lotação'
    from gestores_empresa_contatos g
    where g.ativo and nullif(trim(g.email), '') is not null
      and not exists (select 1 from ev_pessoas p where lower(p.email) = lower(trim(g.email)))
  $q$ using q->>'nome';
  get diagnostics n = row_count;
  perform _ev_log(q, 'Importou ' || n || ' contato(s) dos gestores da lotação');
  return json_build_object('importados', n);
end $$;

-- grava a grade inteira de UMA pessoa: [{tipo, email, whatsapp, empresas[]}]
create or replace function public.ev_inscricoes_salvar(p_token text, p_pessoa bigint, p_lista jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true); x jsonb;
begin
  if not exists (select 1 from ev_pessoas where id = p_pessoa) then raise exception 'Destinatário não encontrado.'; end if;
  delete from ev_inscricoes where pessoa_id = p_pessoa;
  for x in select * from jsonb_array_elements(coalesce(p_lista, '[]')) loop
    if coalesce((x->>'email')::boolean, false) or coalesce((x->>'whatsapp')::boolean, false) then
      insert into ev_inscricoes (pessoa_id, tipo, email, whatsapp, empresas)
      values (p_pessoa, x->>'tipo', coalesce((x->>'email')::boolean, false), coalesce((x->>'whatsapp')::boolean, false),
              coalesce(array(select _ev_emp(z) from jsonb_array_elements_text(coalesce(x->'empresas', '[]')) z where _ev_emp(z) is not null), '{}'));
    end if;
  end loop;
  perform _ev_log(q, 'Mudou o que ' || (select nome from ev_pessoas where id = p_pessoa) || ' recebe', 'ev_inscricoes', p_pessoa::text);
  return 'ok';
end $$;

create or replace function public.ev_tipo_salvar(p_token text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true);
begin
  update ev_tipos set
    nome               = coalesce(nullif(trim(p_dados->>'nome'), ''), nome),
    ativo              = coalesce((p_dados->>'ativo')::boolean, ativo),
    pede_justificativa = coalesce((p_dados->>'pede_justificativa')::boolean, pede_justificativa),
    exige_evidencia    = coalesce((p_dados->>'exige_evidencia')::boolean, exige_evidencia),
    prazo_horas        = coalesce(least(greatest((p_dados->>'prazo_horas')::int, 1), 720), prazo_horas),
    envio              = coalesce(nullif(p_dados->>'envio', ''), envio),
    hora_envio         = coalesce(least(greatest((p_dados->>'hora_envio')::int, 0), 23), hora_envio),
    motivos            = case when p_dados ? 'motivos' then array(select trim(m) from jsonb_array_elements_text(p_dados->'motivos') m where trim(m) <> '') else motivos end,
    opcoes             = case when p_dados ? 'opcoes' then opcoes || (p_dados->'opcoes') else opcoes end
  where codigo = p_dados->>'codigo';
  if not found then raise exception 'Tipo não encontrado.'; end if;
  perform _ev_log(q, 'Ajustou o tipo de evento ' || (p_dados->>'codigo'), 'ev_tipos', p_dados->>'codigo');
  return 'ok';
end $$;

-- botão "Rodar agora": detecta e manda já (ignora a hora do resumo diário)
create or replace function public.ev_rodar_agora(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token, true);
begin
  perform _ev_log(q, 'Rodou os eventos manualmente');
  return ev_rodar(true);
end $$;

-- histórico de envios (fila)
create or replace function public.ev_envios_lista(p_token text, p_dias int default 7) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token);
begin
  return (select coalesce(json_agg(json_build_object('id', v.id, 'tipo', v.tipo, 'nome', v.nome, 'canal', v.canal, 'destino', v.destino,
      'assunto', v.assunto, 'criado_em', v.criado_em, 'enviado_em', v.enviado_em, 'tentativas', v.tentativas, 'erro', v.erro,
      'aberto_em', v.aberto_em, 'eventos', (select count(*) from ev_envio_itens x where x.envio_id = v.id)) order by v.id desc), '[]'::json)
    from ev_envios v where v.criado_em > now() - make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 90)));
end $$;

-- evidência (painel)
create or replace function public.ev_evidencia(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token); r record;
begin
  select nome, tipo, encode(dados, 'base64') as b into r from ev_evidencias where id = p_id;
  if r.nome is null then raise exception 'Evidência não encontrada.'; end if;
  return json_build_object('nome', r.nome, 'tipo', r.tipo, 'base64', replace(r.b, E'\n', ''));
end $$;

-- ---------------------------------------------------------------- página de justificativa (link sem senha)
create or replace function public._ev_link(p_token text) returns public.ev_envios
language sql stable security definer set search_path = public as $$
  select * from ev_envios where token = p_token and p_token like 'tfe\_%' and expira_em > now() limit 1;
$$;
revoke execute on function public._ev_link(text) from public, anon, authenticated;

create or replace function public.ev_link_ver(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare v ev_envios := _ev_link(p_token);
begin
  if v.id is null then return json_build_object('erro', 'Link não encontrado ou vencido. Peça um novo a quem mandou.'); end if;
  update ev_envios set aberto_em = coalesce(aberto_em, now()) where id = v.id;
  return json_build_object(
    'nome', v.nome,
    'tipo', (select json_build_object('codigo', t.codigo, 'nome', t.nome, 'descricao', t.descricao, 'motivos', t.motivos,
               'exige_evidencia', t.exige_evidencia, 'pede_justificativa', t.pede_justificativa) from ev_tipos t where t.codigo = v.tipo),
    'eventos', (select coalesce(json_agg(json_build_object('id', e.id, 'data', e.data, 'titulo', e.titulo, 'frota', e.frota, 'linha', e.linha,
                   'empresa', e.empresa, 'detalhe', e.detalhe, 'situacao', e.situacao, 'prazo', e.prazo, 'motivo', e.motivo,
                   'justificativa', e.justificativa, 'respondido_por', e.respondido_por, 'respondido_em', e.respondido_em,
                   'analise_obs', case when e.situacao = 'refazer' then e.analise_obs end,
                   'evid', (select coalesce(json_agg(json_build_object('id', x.id, 'nome', x.nome, 'tipo', x.tipo, 'tamanho', x.tamanho,
                               'por', x.enviado_por, 'em', x.enviado_em) order by x.id), '[]'::json) from ev_evidencias x where x.evento_id = e.id))
                 order by e.data, e.ocorreu_em), '[]'::json)
               from ev_eventos e where e.id in (select evento_id from ev_envio_itens where envio_id = v.id)));
end $$;

-- p_evid = [{nome, tipo, base64}] (até 5 arquivos de 5 MB)
create or replace function public.ev_link_responder(p_token text, p_evento bigint, p_motivo text, p_texto text, p_nome text, p_evid jsonb default null) returns text
language plpgsql security definer set search_path = public as $$
declare v ev_envios := _ev_link(p_token); e ev_eventos; t ev_tipos; x jsonb; b bytea; nev int := 0; quem text;
begin
  if v.id is null then raise exception 'Link não encontrado ou vencido.'; end if;
  if not exists (select 1 from ev_envio_itens where envio_id = v.id and evento_id = p_evento) then raise exception 'Evento não pertence a este link.'; end if;
  select * into e from ev_eventos where id = p_evento;
  select * into t from ev_tipos where codigo = e.tipo;
  if e.situacao in ('aceito', 'encerrado') then raise exception 'Este evento já foi encerrado.'; end if;
  if length(trim(coalesce(p_nome, ''))) < 3 then raise exception 'Escreva o seu nome.'; end if;
  if cardinality(t.motivos) > 0 and coalesce(trim(p_motivo), '') = '' then raise exception 'Escolha o motivo.'; end if;
  if t.pede_justificativa and length(trim(coalesce(p_texto, ''))) < 10 then raise exception 'Explique o que aconteceu (pelo menos uma frase).'; end if;
  if jsonb_typeof(p_evid) = 'array' and jsonb_array_length(p_evid) > 5 then raise exception 'Mande no máximo 5 arquivos por vez.'; end if;
  if t.exige_evidencia and coalesce(jsonb_array_length(case when jsonb_typeof(p_evid) = 'array' then p_evid end), 0) = 0
     and not exists (select 1 from ev_evidencias where evento_id = p_evento and enviado_em > coalesce(e.analise_em, '-infinity')) then
    raise exception 'Anexe a evidência (foto, print do sistema, documento).';
  end if;
  quem := left(trim(p_nome), 80) || ' (' || coalesce(v.nome, 'link') || ')';
  if jsonb_typeof(p_evid) = 'array' then
    for x in select * from jsonb_array_elements(p_evid) loop
      b := decode(coalesce(x->>'base64', ''), 'base64');
      if length(b) = 0 then continue; end if;
      if length(b) > 5 * 1024 * 1024 then raise exception 'O arquivo % passa de 5 MB.', coalesce(x->>'nome', ''); end if;
      insert into ev_evidencias (evento_id, nome, tipo, tamanho, dados, enviado_por)
      values (p_evento, left(coalesce(nullif(trim(x->>'nome'), ''), 'evidencia'), 120), nullif(x->>'tipo', ''), length(b), b, quem);
      nev := nev + 1;
    end loop;
  end if;
  update ev_eventos set situacao = 'justificado', motivo = nullif(trim(coalesce(p_motivo, '')), ''),
    justificativa = nullif(trim(coalesce(p_texto, '')), ''), respondido_por = quem, respondido_em = now()
   where id = p_evento;
  insert into ev_historico (evento_id, quem, acao, texto) values (p_evento, quem, 'justificado',
    coalesce(nullif(trim(p_motivo), '') || ' — ', '') || coalesce(trim(p_texto), '') ||
    case when nev > 0 then ' (' || nev || ' evidência(s))' else '' end);
  return 'ok';
end $$;

create or replace function public.ev_link_evidencia(p_token text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare v ev_envios := _ev_link(p_token); r record;
begin
  if v.id is null then raise exception 'Link vencido.'; end if;
  select x.nome, x.tipo, encode(x.dados, 'base64') as b into r from ev_evidencias x
   where x.id = p_id and x.evento_id in (select evento_id from ev_envio_itens where envio_id = v.id);
  if r.nome is null then raise exception 'Evidência não encontrada.'; end if;
  return json_build_object('nome', r.nome, 'tipo', r.tipo, 'base64', replace(r.b, E'\n', ''));
end $$;

-- mapa da viagem (GPS do Monitor + cerca), igual ao do BI, para o painel (token da Central) e para o link
create or replace function public._ev_trilha(p_evento bigint) returns json
language plpgsql stable security definer set search_path = public as $$
declare e ev_eventos; f text; prev timestamptz; v_real timestamptz; de timestamptz; ate timestamptz;
begin
  select * into e from ev_eventos where id = p_evento;
  if e.id is null or e.tipo <> 'pontualidade' then return null; end if;
  f := public.normaliza_tag(e.frota);
  prev := (e.data + (e.detalhe->>'prevista')::time)::timestamp at time zone 'America/Belem';
  v_real := coalesce(e.ocorreu_em, prev);
  de := least(prev, v_real) - interval '40 minutes';
  ate := greatest(prev, v_real) + interval '20 minutes';
  return json_build_object('prevista', prev, 'real', v_real,
    'pontos', (select coalesce(json_agg(json_build_object('ts', ts, 'lat', lat, 'lon', lon) order by ts), '[]'::json)
               from samples where ts between de and ate and lat is not null and lon is not null and not (lat = 0 and lon = 0)
                 and public.normaliza_tag(device_name) = f),
    'eventos', (select coalesce(json_agg(json_build_object('ts', x.ts, 'tipo', x.tipo, 'gap_min', x.gap_min) order by x.ts), '[]'::json)
               from bi_cerca_eventos x join bi_cercas c on c.id = x.cerca_id
               where x.frota = f and x.ts between de and ate and c.nome = e.detalhe->>'cerca'),
    'cerca', (select json_build_object('nome', nome, 'cor', cor, 'pontos', pontos) from bi_cercas where nome = e.detalhe->>'cerca' limit 1));
end $$;
revoke execute on function public._ev_trilha(bigint) from public, anon, authenticated;

create or replace function public.ev_trilha(p_token text, p_evento bigint) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._ev_exige(p_token);
begin return _ev_trilha(p_evento); end $$;

create or replace function public.ev_link_trilha(p_token text, p_evento bigint) returns json
language plpgsql security definer set search_path = public as $$
declare v ev_envios := _ev_link(p_token);
begin
  if v.id is null or not exists (select 1 from ev_envio_itens where envio_id = v.id and evento_id = p_evento) then
    raise exception 'Link vencido.';
  end if;
  return _ev_trilha(p_evento);
end $$;

-- ---------------------------------------------------------------- robôs de envio
-- E-mail: robô Apps Script do quadro de Demandas (mesma chave em sol_config.chave_robo)
create or replace function public.ev_emails_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  return json_build_object('link', (select link from ev_config where id = 1),
    'envios', coalesce((select json_agg(json_build_object('id', v.id, 'para', v.destino, 'assunto', v.assunto, 'texto', v.texto,
                 'link', (select link from ev_config where id = 1) || '?t=' || v.token) order by v.id)
      from (select * from ev_envios where canal = 'email' and enviado_em is null and tentativas < 5 and expira_em > now()
            order by id limit 20) v), '[]'::json));
end $$;

create or replace function public.ev_email_marcar(p_chave text, p_id bigint, p_ok boolean, p_erro text default null) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  update ev_envios set enviado_em = case when p_ok then now() end, tentativas = tentativas + 1,
    erro = case when p_ok then null else left(p_erro, 500) end where id = p_id and canal = 'email';
  return 'ok';
end $$;

-- WhatsApp: n8n da TV Box (service_role) + Evolution
create or replace function public.ev_whats_pendentes(p_limite integer default 5) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('avisos', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'numero', v.destino,
      'texto', '🚌 *' || v.assunto || '*' || chr(10) || chr(10) || v.texto || chr(10) || chr(10) ||
               '👉 Justificar e anexar a evidência:' || chr(10) || (select link from ev_config where id = 1) || '?t=' || v.token) order by v.id)
    from (select * from ev_envios where canal = 'whatsapp' and enviado_em is null and tentativas < 3 and expira_em > now()
            and criado_em > now() - interval '12 hours'
          order by id limit greatest(1, least(coalesce(p_limite, 5), 20))) v), '[]'::jsonb));
end $$;

create or replace function public.ev_whats_marcar(p_id bigint, p_ok boolean, p_erro text default null) returns text
language sql security definer set search_path = public as $$
  update ev_envios set enviado_em = case when p_ok then now() end, tentativas = tentativas + 1,
    erro = case when p_ok then null else left(p_erro, 500) end where id = p_id and canal = 'whatsapp';
  select 'ok';
$$;
revoke all on function public.ev_whats_pendentes(integer), public.ev_whats_marcar(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.ev_whats_pendentes(integer), public.ev_whats_marcar(bigint, boolean, text) to service_role;

-- ---------------------------------------------------------------- permissões das funções públicas
grant execute on function public.ev_entrar(text), public.ev_sessao(text), public.ev_sair(text),
  public.ev_painel(text, date, date), public.ev_detalhe(text, bigint), public.ev_analisar(text, bigint, text, text),
  public.ev_pessoa_salvar(text, jsonb), public.ev_pessoa_remover(text, bigint), public.ev_importar_gestores(text),
  public.ev_inscricoes_salvar(text, bigint, jsonb), public.ev_tipo_salvar(text, jsonb), public.ev_rodar_agora(text),
  public.ev_envios_lista(text, int), public.ev_evidencia(text, bigint), public.ev_trilha(text, bigint),
  public.ev_link_ver(text), public.ev_link_responder(text, bigint, text, text, text, jsonb),
  public.ev_link_evidencia(text, bigint), public.ev_link_trilha(text, bigint),
  public.ev_emails_pendentes(text), public.ev_email_marcar(text, bigint, boolean, text)
  to anon, authenticated;

-- ---------------------------------------------------------------- agendamento (pg_cron): a cada 15 min
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'eventos-rodar';
select cron.schedule('eventos-rodar', '*/15 * * * *', 'select public.ev_rodar()');

notify pgrst, 'reload schema';
select 'Eventos pronto' as status, (select count(*) from public.ev_tipos) as tipos, (select count(*) from public.ev_pessoas) as destinatarios;
