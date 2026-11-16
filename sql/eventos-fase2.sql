-- =====================================================================
-- EVENTOS — FASE 2: roteador, passageiro fora de rota e aberturas erradas também
-- avisam pelo painel Eventos (e-mail e/ou WhatsApp, por pessoa, em "Quem recebe o quê").
--
-- Como funciona: os fluxos antigos continuam criando os registros (roteador_tratativas,
-- consultas, abt_casos) e mandando os avisos de sempre (e-mail do roteador, gestor da
-- pessoa na lotação, demanda da Caliman). Este SQL faz o painel mandar TAMBÉM um aviso
-- com o link de cada item para quem estiver marcado no tipo, pelo canal marcado,
-- respeitando o filtro de empresa (só itens cuja empresa é conhecida entram no filtro).
-- A tratativa continua na página de origem (link do aviso).
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run, DEPOIS do eventos.sql. Pode rodar de novo.
-- =====================================================================

alter table public.ev_envios add column if not exists link text;   -- link próprio (página de origem); vazio = link de justificativa

create table if not exists public.ev_externo_enviados (
  tipo      text not null,
  item      text not null,
  pessoa_id bigint not null references public.ev_pessoas(id) on delete cascade,
  canal     text not null,
  envio_id  bigint references public.ev_envios(id) on delete set null,
  em        timestamptz not null default now(),
  primary key (tipo, item, pessoa_id, canal)
);
alter table public.ev_externo_enviados enable row level security;
revoke all on public.ev_externo_enviados from anon, authenticated;

alter table public.ev_config add column if not exists link_roteador text not null default 'https://zael20.github.io/painel-mes-tfleet-bdv/roteador-tratativa.html';
alter table public.ev_config add column if not exists link_resposta text not null default 'https://zael20.github.io/painel-mes-tfleet-bdv/resposta.html';
alter table public.ev_config add column if not exists link_aberturas text not null default 'https://gestao-integrada.github.io/aberturas/';
alter table public.ev_config add column if not exists horas_externos int not null default 48;   -- só avisa itens criados nas últimas X horas

update public.ev_tipos set descricao = 'Celular do ônibus usado como roteador (hotspot). Aviso com o link da tratativa; o e-mail antigo do roteador continua.'
 where codigo = 'roteador';
update public.ev_tipos set descricao = 'Passageiro embarcando em rota diferente da cadastrada. O gestor da pessoa continua recebendo; aqui vai uma cópia com o link da resposta.'
 where codigo = 'fora_rota';
update public.ev_tipos set descricao = 'Viagem aberta errado no app (sentido, rota). Continua indo como demanda para a Caliman; aqui vai o aviso com o link do painel.'
 where codigo = 'abertura';

-- empresa do carro pela viagem mais recente dele
create or replace function public._ev_emp_frota(p_frota text) returns text
language sql stable security definer set search_path = public as $$
  select public._ev_emp(to_jsonb(v)->>'empresa') from viagens v
  where public.normaliza_tag(v.frota) = public.normaliza_tag(p_frota) and v.data_local > public._ev_hoje() - 30
  order by v.data_local desc, v.coletado_em desc nulls last limit 1;
$$;
revoke execute on function public._ev_emp_frota(text) from public, anon, authenticated;

-- itens recentes ainda sem resposta dos 3 tipos de fora: (tipo, item, empresa, linha do aviso, link)
create or replace function public._ev_externos_itens() returns table (tipo text, item text, empresa text, linha text, link text, ts timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare cfg ev_config; desde timestamptz;
begin
  select * into cfg from ev_config where id = 1;
  desde := now() - make_interval(hours => greatest(cfg.horas_externos, 1));
  if to_regclass('public.roteador_tratativas') is not null and to_regclass('public.events') is not null then
    return query execute $q$
      select 'roteador'::text, t.event_id::text,
             public._ev_emp_frota(coalesce(to_jsonb(t)->>'carro', nullif(e.device_name, ''), e.device_id)),
             to_char(e.ts at time zone 'America/Belem', 'DD/MM HH24:MI') || ' · carro ' ||
               coalesce(to_jsonb(t)->>'carro', nullif(e.device_name, ''), e.device_id) || ' usou o roteador' ||
               coalesce(' (' || round(nullif(e.detail->>'mb_usados', '')::numeric, 1) || ' MB)', '') ||
               coalesce(' · possível motorista: ' || nullif(to_jsonb(t)->>'motorista_sugerido', ''), ''),
             $1 || '?t=' || t.token, t.criado_em
      from roteador_tratativas t join events e on e.id = t.event_id
      where t.criado_em >= $2 and t.tratado_em is null $q$ using cfg.link_roteador, desde;
  end if;
  if to_regclass('public.consultas') is not null then
    return query execute $q$
      select 'fora_rota'::text, c.id::text, null::text,
             coalesce(c.nome, c.matricula, 'Passageiro') || ' usou ' || coalesce(c.linha_usada, '?') ||
               ' (cadastro: ' || coalesce(c.linha_cadastro, 'sem linha') || ') em ' || coalesce(c.dias, 0) || ' dia(s)' ||
               coalesce(' · gestor: ' || nullif(c.enviado_para, ''), ''),
             $1 || '?t=' || c.token, c.criado_em
      from consultas c
      where c.criado_em >= $2 and c.respondido_em is null $q$ using cfg.link_resposta, desde;
  end if;
  if to_regclass('public.abt_casos') is not null then
    return query execute $q$
      select 'abertura'::text, a.viagem_id || '|' || a.regra,
             coalesce(public._ev_emp((select to_jsonb(v)->>'empresa' from viagens v where v.id = a.viagem_id)), public._ev_emp_frota(a.frota)),
             to_char(a.data_local, 'DD/MM') || ' ' || coalesce(to_char(a.hora, 'HH24:MI'), '') || ' · carro ' || coalesce(a.frota, '?') ||
               ' · ' || coalesce(a.linha, '') || ' ' || coalesce(a.tipo, '') || ' · ' || coalesce(a.problema, a.regra),
             $1, a.detectado_em
      from abt_casos a
      where a.detectado_em >= $2 and a.situacao = 'aberto' $q$ using cfg.link_aberturas, desde;
  end if;
end $$;
revoke execute on function public._ev_externos_itens() from public, anon, authenticated;

-- monta a fila dos 3 tipos de fora (mesma regra da pontualidade: na hora ou 1x por dia)
create or replace function public._ev_montar_externos(p_forcar boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare t ev_tipos; i record; c text; dest text; n int := 0; eid bigint; tk text; cfg ev_config;
  hoje date := _ev_hoje(); hora int := extract(hour from now() at time zone 'America/Belem');
  itens jsonb; qtd int; lista text; lk text; pag text;
begin
  select * into cfg from ev_config where id = 1;
  create temp table if not exists _ev_x (tipo text, item text, empresa text, linha text, link text, ts timestamptz) on commit drop;
  truncate _ev_x;
  insert into _ev_x select * from _ev_externos_itens();
  for t in select * from ev_tipos where origem = 'externo' and ativo loop
    if not p_forcar and t.envio = 'diario' and (hora < t.hora_envio or t.ultimo_envio = hoje) then continue; end if;
    pag := case t.codigo when 'roteador' then cfg.link_roteador when 'fora_rota' then cfg.link_resposta else cfg.link_aberturas end;
    for i in select p.*, s.email as q_email, s.whatsapp as q_whats, s.empresas
               from ev_inscricoes s join ev_pessoas p on p.id = s.pessoa_id
              where s.tipo = t.codigo and p.ativo and (s.email or s.whatsapp) loop
      foreach c in array array['email', 'whatsapp'] loop
        if c = 'email' and not (i.q_email and coalesce(trim(i.email), '') like '%@%') then continue; end if;
        if c = 'whatsapp' and not (i.q_whats and _ev_fone(i.whatsapp) is not null) then continue; end if;
        dest := case when c = 'email' then lower(trim(i.email)) else _ev_fone(i.whatsapp) end;
        select jsonb_agg(jsonb_build_object('item', x.item, 'linha', x.linha, 'link', x.link) order by x.ts), count(*)
          into itens, qtd
          from _ev_x x
         where x.tipo = t.codigo
           and (cardinality(i.empresas) = 0 or x.empresa = any (i.empresas))
           and not exists (select 1 from ev_externo_enviados z where z.tipo = x.tipo and z.item = x.item and z.pessoa_id = i.id and z.canal = c);
        if coalesce(qtd, 0) = 0 then continue; end if;
        select string_agg('• ' || (e->>'linha') ||
                 case when t.codigo <> 'abertura' then chr(10) || '  ' || (e->>'link') else '' end, chr(10))
          into lista from (select e from jsonb_array_elements(itens) e limit 15) z;
        if qtd > 15 then lista := lista || chr(10) || '… e mais ' || (qtd - 15) || '.'; end if;
        lk := case when qtd = 1 then itens->0->>'link' else pag end;
        tk := 'tfe_' || encode(gen_random_bytes(18), 'hex');
        insert into ev_envios (tipo, pessoa_id, nome, canal, destino, token, assunto, texto, expira_em, link)
        values (t.codigo, i.id, i.nome, c, dest, tk,
                t.nome || ': ' || qtd || ' novo(s)',
                'Olá, ' || split_part(i.nome, ' ', 1) || '.' || chr(10) || chr(10) ||
                qtd || ' registro(s) de ' || lower(t.nome) || ' sem tratativa:' || chr(10) || chr(10) || lista ||
                case t.codigo when 'roteador' then chr(10) || chr(10) || 'Registre a tratativa pelo link de cada uso.'
                              when 'fora_rota' then chr(10) || chr(10) || 'O gestor da pessoa responde pelo link (esta é uma cópia).'
                              else chr(10) || chr(10) || 'Os casos estão no painel Aberturas erradas.' end,
                now() + make_interval(days => cfg.dias_link), lk)
        returning id into eid;
        insert into ev_externo_enviados (tipo, item, pessoa_id, canal, envio_id)
        select t.codigo, e->>'item', i.id, c, eid from jsonb_array_elements(itens) e
        on conflict do nothing;
        n := n + 1;
      end loop;
    end loop;
    if t.envio = 'diario' then update ev_tipos set ultimo_envio = hoje where codigo = t.codigo; end if;
  end loop;
  return n;
end $$;
revoke execute on function public._ev_montar_externos(boolean) from public, anon, authenticated;

-- rodada completa agora inclui os 3 tipos de fora
create or replace function public.ev_rodar(p_forcar boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare g int := 0; m int; x int := 0;
begin
  begin
    g := _ev_gerar_pontualidade();
  exception when others then
    raise warning 'eventos: pontualidade falhou: %', sqlerrm;
  end;
  m := _ev_montar_envios(p_forcar);
  begin
    x := _ev_montar_externos(p_forcar);
  exception when others then
    raise warning 'eventos: roteador/fora de rota/aberturas falhou: %', sqlerrm;
  end;
  return g || ' evento(s) novo(s); ' || (m + x) || ' mensagem(ns) na fila.';
end $$;
revoke execute on function public.ev_rodar(boolean) from public, anon, authenticated;

-- robôs: usam o link próprio quando tiver (roteador, resposta do gestor, aberturas)
create or replace function public.ev_emails_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  return json_build_object('link', (select link from ev_config where id = 1),
    'envios', coalesce((select json_agg(json_build_object('id', v.id, 'para', v.destino, 'assunto', v.assunto, 'texto', v.texto,
                 'link', coalesce(v.link, (select link from ev_config where id = 1) || '?t=' || v.token),
                 'botao', case v.tipo when 'roteador' then 'Registrar a tratativa' when 'fora_rota' then 'Ver a consulta'
                                      when 'abertura' then 'Abrir Aberturas erradas' else 'Justificar e anexar evidência' end) order by v.id)
      from (select * from ev_envios where canal = 'email' and enviado_em is null and tentativas < 5 and expira_em > now()
            order by id limit 20) v), '[]'::json));
end $$;

create or replace function public.ev_whats_pendentes(p_limite integer default 5) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('avisos', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'numero', v.destino,
      'texto', '🚌 *' || v.assunto || '*' || chr(10) || chr(10) || v.texto || chr(10) || chr(10) ||
               case when v.link is null then '👉 Justificar e anexar a evidência:' || chr(10) || (select link from ev_config where id = 1) || '?t=' || v.token
                    else '👉 Abrir:' || chr(10) || v.link end) order by v.id)
    from (select * from ev_envios where canal = 'whatsapp' and enviado_em is null and tentativas < 3 and expira_em > now()
            and criado_em > now() - interval '12 hours'
          order by id limit greatest(1, least(coalesce(p_limite, 5), 20))) v), '[]'::jsonb));
end $$;
revoke all on function public.ev_whats_pendentes(integer) from public, anon, authenticated;
grant execute on function public.ev_whats_pendentes(integer) to service_role;
grant execute on function public.ev_emails_pendentes(text) to anon, authenticated;

notify pgrst, 'reload schema';
select 'Eventos fase 2 pronta' as status,
  (select count(*) from public.ev_tipos where origem = 'externo' and ativo) as tipos_de_fora_ligados;
