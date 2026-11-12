-- =====================================================================
-- COLETA DA API TFLEET DENTRO DO SUPABASE (sem depender do n8n)
-- A cada 30 min o próprio Supabase chama a API da TFleet (BdvCompletoHoje = viagens e
-- OcupacaoHoje = embarques) e grava nas mesmas tabelas viagens e embarques que o BI, a Lotação
-- e as Aberturas já usam. Usa o MESMO id que o fluxo do n8n: se o n8n voltar, os dois não duplicam.
--
-- Como ligar (uma vez):
--   1) Supabase → Database → Extensions: ligar pg_net e pg_cron (ou deixar este SQL ligar).
--   2) Rodar este arquivo inteiro no SQL Editor.
--   3) Rodar, com os seus dados da TFleet (os mesmos do n8n), num SQL separado:
--        update public.bi_coleta_cfg set acesso = 'SEU_ACESSO', token = 'SEU_TOKEN' where id = 1;
--      O acesso e o token ficam numa tabela que ninguém lê pela internet (só o próprio banco).
--   4) No BI, aba ⚙ Gerenciar → "Coletar agora", e conferir o resultado em "Coleta da TFleet".
-- Depende de: lotacao.sql (viagens, embarques) e bi.sql.
-- =====================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.bi_coleta_cfg (
  id         int primary key default 1 check (id = 1),
  acesso     text,
  token      text,
  ativo      boolean not null default true,
  url_base   text not null default 'https://indicadores.tfleet.com.br/api/service-import/'
);
insert into public.bi_coleta_cfg (id) values (1) on conflict (id) do nothing;

create table if not exists public.bi_coleta_log (
  id            bigserial primary key,
  endpoint      text not null,
  req_id        bigint,
  disparado_em  timestamptz not null default now(),
  processado_em timestamptz,
  status        int,
  linhas        int,
  erro          text,
  por           text
);
create index if not exists bi_coleta_log_pend on public.bi_coleta_log (processado_em) where processado_em is null;

alter table public.bi_coleta_cfg enable row level security;
alter table public.bi_coleta_log enable row level security;
revoke all on public.bi_coleta_cfg, public.bi_coleta_log from anon, authenticated;

-- ---------------------------------------------------------------- conversões (iguais ao código do n8n)
create or replace function public._bi_txt(v text) returns text language sql immutable as $$ select nullif(trim(v), '') $$;
create or replace function public._bi_num(v text) returns numeric language plpgsql immutable as $$
begin return replace(trim(v), ',', '.')::numeric; exception when others then return null; end $$;
-- "20/10/2026" + "04:14:19" (hora de Belém) → timestamptz
create or replace function public._bi_ts(d text, h text) returns timestamptz language plpgsql immutable as $$
begin
  if d !~ '^\s*\d{2}/\d{2}/\d{4}\s*$' or h !~ '^\s*\d{1,2}:\d{2}(:\d{2})?\s*$' then return null; end if;
  return (to_date(trim(d), 'DD/MM/YYYY') + trim(h)::time)::timestamp at time zone 'America/Belem';
exception when others then return null; end $$;

-- grava a resposta de um endpoint; devolve quantas linhas entraram
create or replace function public._bi_coleta_gravar(p_endpoint text, p_resp jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare arr jsonb; n int := 0; hoje date := (now() at time zone 'America/Belem')::date;
begin
  arr := case when jsonb_typeof(p_resp) = 'array' then p_resp
              when jsonb_typeof(p_resp -> 'result') = 'array' then p_resp -> 'result' else '[]'::jsonb end;
  if p_endpoint = 'BdvCompletoHoje' then
    with r as (
      select v, coalesce(_bi_ts(v->>'datasaida', v->>'Hrsaida'),
                         case when v->>'data' ~ '^\d{4}-\d{2}-\d{2}T' then (v->>'data')::timestamptz end) as saida,
             _bi_ts(v->>'datachegada', v->>'hrchegada') as chegada
      from jsonb_array_elements(arr) v
    ), linhas as (
      select distinct on (id) * from (
        select concat_ws('|', coalesce(_bi_txt(v->>'placa'), _bi_txt(v->>'frota'), '?'),
                         to_char(saida at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), coalesce(_bi_txt(v->>'tipo'), '')) as id,
               v, saida, chegada from r where saida is not null) z
      order by id
    )
    insert into viagens (id, coletado_em, placa, frota, empresa, origem, tipolinha, linha, tipo, motorista, data_local, hora_saida,
                         saida_ts, chegada_ts, ocupacao, km, lat_saida, lon_saida, bruto)
    select id, now(), _bi_txt(v->>'placa'), _bi_txt(v->>'frota'), _bi_txt(v->>'empresa'), _bi_txt(v->>'origem'), _bi_txt(v->>'tipolinha'),
           _bi_txt(v->>'linha'), _bi_txt(v->>'tipo'), _bi_txt(v->>'motorista'), (saida at time zone 'America/Belem')::date,
           (saida at time zone 'America/Belem')::time, saida, chegada, round(_bi_num(v->>'ocupacao'))::int, _bi_num(v->>'kmpercorrido'),
           _bi_num(v->>'latitudesaida')::float8, _bi_num(v->>'Longitudesaida')::float8, v
    from linhas
    on conflict (id) do update set coletado_em = excluded.coletado_em, placa = excluded.placa, frota = excluded.frota,
      empresa = excluded.empresa, origem = excluded.origem, tipolinha = excluded.tipolinha, linha = excluded.linha, tipo = excluded.tipo,
      motorista = excluded.motorista, data_local = excluded.data_local, hora_saida = excluded.hora_saida, saida_ts = excluded.saida_ts,
      chegada_ts = excluded.chegada_ts, ocupacao = excluded.ocupacao, km = excluded.km, lat_saida = excluded.lat_saida,
      lon_saida = excluded.lon_saida, bruto = excluded.bruto;
    get diagnostics n = row_count;
  elsif p_endpoint = 'OcupacaoHoje' then
    with r as (
      select e, case when e->>'hora' ~ '^\s*\d{1,2}:\d{2}' then lpad(split_part(trim(e->>'hora'), ':', 1), 2, '0') || ':' || substr(split_part(trim(e->>'hora'), ':', 2), 1, 2) end as h,
             coalesce(case when e->>'datadesembarque' ~ '^\s*\d{2}/\d{2}/\d{4}\s*$' then to_date(trim(e->>'datadesembarque'), 'DD/MM/YYYY') end, hoje) as d
      from jsonb_array_elements(arr) e
    ), linhas as (
      select distinct on (id) * from (
        select concat_ws('|', coalesce(_bi_txt(e->>'matricula'), _bi_txt(e->>'codigoid'), _bi_txt(e->>'nome'), '?'),
                         coalesce(_bi_txt(e->>'placa'), _bi_txt(e->>'frota'), '?'), to_char(d, 'YYYY-MM-DD'), h, coalesce(_bi_txt(e->>'tipoviagem'), '')) as id,
               e, h, d from r where h is not null) z
      order by id
    )
    insert into embarques (id, coletado_em, data_local, hora, nome, matricula, tipopassageiro, placa, frota, tipolinha, turno, linha, sentido,
                           linhapassageiro, ga, gg, centrocusto, lat, lon, hora_desembarque, lat_desembarque, lon_desembarque, bruto)
    select id, now(), d, h::time, _bi_txt(e->>'nome'), _bi_txt(e->>'matricula'), _bi_txt(e->>'tipopassageiro'), _bi_txt(e->>'placa'),
           _bi_txt(e->>'frota'), _bi_txt(e->>'tipolinha'), _bi_txt(e->>'tipo'), _bi_txt(e->>'linha'), _bi_txt(e->>'tipoviagem'),
           _bi_txt(e->>'linhapassageiro'), _bi_txt(e->>'GA'), _bi_txt(e->>'GG'), _bi_txt(e->>'centrocusto'),
           _bi_num(e->>'latitudeembarque')::float8, _bi_num(e->>'longitudeembarque')::float8,
           case when e->>'horadesembarque' ~ '^\s*\d{1,2}:\d{2}' then substr(trim(e->>'horadesembarque'), 1, 5)::time end,
           _bi_num(e->>'latitudedesembarque')::float8, _bi_num(e->>'longitudedesembarque')::float8, e
    from linhas
    on conflict (id) do update set coletado_em = excluded.coletado_em, nome = excluded.nome, matricula = excluded.matricula,
      tipopassageiro = excluded.tipopassageiro, placa = excluded.placa, frota = excluded.frota, tipolinha = excluded.tipolinha,
      turno = excluded.turno, linha = excluded.linha, sentido = excluded.sentido, linhapassageiro = excluded.linhapassageiro,
      ga = excluded.ga, gg = excluded.gg, centrocusto = excluded.centrocusto, lat = excluded.lat, lon = excluded.lon,
      hora_desembarque = excluded.hora_desembarque, lat_desembarque = excluded.lat_desembarque,
      lon_desembarque = excluded.lon_desembarque, bruto = excluded.bruto;
    get diagnostics n = row_count;
  end if;
  return n;
end $$;
revoke execute on function public._bi_coleta_gravar(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- disparar e processar
-- dispara as 2 chamadas (a resposta chega depois, em net._http_response)
create or replace function public.bi_coleta_disparar(p_por text default 'agendado') returns text
language plpgsql security definer set search_path = public, net as $$
declare c bi_coleta_cfg; ep text; rid bigint;
begin
  select * into c from bi_coleta_cfg where id = 1;
  if not c.ativo then return 'desligada'; end if;
  if coalesce(c.acesso, '') = '' or coalesce(c.token, '') = '' then return 'falta acesso/token em bi_coleta_cfg'; end if;
  foreach ep in array array['BdvCompletoHoje', 'OcupacaoHoje'] loop
    select net.http_post(url := c.url_base || ep, body := jsonb_build_object('acesso', c.acesso, 'token', c.token),
                         headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 120000) into rid;
    insert into bi_coleta_log (endpoint, req_id, por) values (ep, rid, p_por);
  end loop;
  return 'ok';
end $$;
revoke execute on function public.bi_coleta_disparar(text) from public, anon, authenticated;

-- lê as respostas que já chegaram e grava
create or replace function public.bi_coleta_processar() returns int
language plpgsql security definer set search_path = public, net as $$
declare l record; r record; n int; feitos int := 0;
begin
  for l in select * from bi_coleta_log where processado_em is null order by id loop
    select * into r from net._http_response where id = l.req_id;
    if r.id is null then
      if l.disparado_em < now() - interval '15 minutes' then
        update bi_coleta_log set processado_em = now(), erro = 'sem resposta da TFleet em 15 min' where id = l.id;
      end if;
      continue;
    end if;
    begin
      if r.timed_out or r.error_msg is not null then
        update bi_coleta_log set processado_em = now(), status = r.status_code, erro = coalesce(r.error_msg, 'tempo esgotado') where id = l.id;
      elsif r.status_code <> 200 then
        update bi_coleta_log set processado_em = now(), status = r.status_code, erro = left(r.content, 300) where id = l.id;
      else
        n := _bi_coleta_gravar(l.endpoint, r.content::jsonb);
        update bi_coleta_log set processado_em = now(), status = 200, linhas = n where id = l.id;
      end if;
    exception when others then
      update bi_coleta_log set processado_em = now(), status = r.status_code, erro = left(sqlerrm, 300) where id = l.id;
    end;
    feitos := feitos + 1;
  end loop;
  delete from bi_coleta_log where disparado_em < now() - interval '30 days';
  return feitos;
end $$;
revoke execute on function public.bi_coleta_processar() from public, anon, authenticated;

-- agenda: chama a API a cada 30 min e grava as respostas a cada minuto
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('bi-coleta-disparar', 'bi-coleta-processar');
end $$;
select cron.schedule('bi-coleta-disparar', '*/30 * * * *', $$select public.bi_coleta_disparar()$$);
select cron.schedule('bi-coleta-processar', '* * * * *', $$select public.bi_coleta_processar()$$);

-- ---------------------------------------------------------------- para a página do BI
create or replace function public.bi_coleta_status(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  return json_build_object(
    'configurada', (select coalesce(acesso, '') <> '' and coalesce(token, '') <> '' from bi_coleta_cfg where id = 1),
    'ativa', (select ativo from bi_coleta_cfg where id = 1),
    'ultima_viagem', (select max(coletado_em) from viagens),
    'ultimo_embarque', (select max(coletado_em) from embarques),
    'log', (select coalesce(json_agg(x order by x.id desc), '[]'::json) from (
              select id, endpoint, disparado_em, processado_em, status, linhas, erro, por from bi_coleta_log order by id desc limit 12) x));
end $$;

create or replace function public.bi_coleta_agora(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true);
begin
  if exists (select 1 from bi_coleta_log where disparado_em > now() - interval '2 minutes') then
    return 'Já tem uma coleta rodando. Espere 2 minutos.';
  end if;
  return public.bi_coleta_disparar(q->>'nome');
end $$;

grant execute on function public.bi_coleta_status(text), public.bi_coleta_agora(text) to anon, authenticated;
notify pgrst, 'reload schema';
