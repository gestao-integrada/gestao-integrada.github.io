-- =====================================================================
-- ARQUIVO DAS AMOSTRAS DO MONITOR (banco do Supabase no limite de 500 MB)
-- A tabela samples (1 leitura por minuto de cada celular) cresce ~26 MB por dia.
-- Como fica:
--   1) Supabase guarda a leitura COMPLETA só dos últimos 7 dias (arq_config.dias_supabase);
--   2) cada dia inteiro vai, compactado (.csv.gz), para uma pasta do Google Drive pelo robô do
--      Apps Script (sql/arquivo-amostras.gs). samples_arquivo registra o dia, as linhas e o link;
--   3) fica para consultar no Supabase:
--        samples_dia  = resumo por celular por dia (já existia; para sempre);
--        samples_gps  = GPS enxuto (cada minuto andando, a cada 5 min parado) por 90 dias (arq_config.dias_gps);
--   4) a limpeza diária (03:30) só apaga do Supabase o dia que JÁ está no Drive.
--      Proteção: se o robô parar, depois de arq_config.teto_dias (14) apaga mesmo assim para o banco não travar
--      (o resumo e o GPS enxuto desses dias ficam).
-- A última leitura de cada celular nunca é apagada.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo. NÃO apaga nada ao rodar.
-- Depende de: schema do Monitor (samples, device_config), limpeza-amostras.sql (samples_dia), solicitacoes.sql
-- (sol_config.chave_robo) e central-acessos.sql (página de consulta).
-- =====================================================================

create extension if not exists pg_cron;

create table if not exists public.arq_config (
  id             int primary key default 1 check (id = 1),
  dias_supabase  int not null default 7,     -- leitura completa no Supabase
  dias_gps       int not null default 90,    -- GPS enxuto no Supabase
  teto_dias      int not null default 14,    -- apaga mesmo sem arquivo depois disso (proteção do banco)
  pasta_drive    text not null default 'Monitor Frota - amostras'
);
insert into public.arq_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.samples_arquivo (
  dia          date primary key,
  linhas       int,
  bytes        bigint,
  arquivo_id   text,
  link         text,
  arquivado_em timestamptz not null default now()
);

create table if not exists public.samples_gps (
  device_id text not null,
  frota     text,
  ts        timestamptz not null,
  lat       double precision not null,
  lon       double precision not null,
  speed_kmh real,
  primary key (device_id, ts)
);
create index if not exists samples_gps_frota_ts on public.samples_gps (frota, ts);
create index if not exists samples_gps_ts on public.samples_gps (ts);

create table if not exists public.arq_log (
  id  bigserial primary key,
  ts  timestamptz not null default now(),
  resultado jsonb
);

alter table public.arq_config      enable row level security;   -- sem policy: só pelas funções
alter table public.samples_arquivo enable row level security;
alter table public.samples_gps     enable row level security;
alter table public.arq_log         enable row level security;
revoke all on public.arq_config, public.samples_arquivo, public.samples_gps, public.arq_log from anon, authenticated;

-- ---------------------------------------------------------------- GPS enxuto de um dia (Belém)
create or replace function public._arq_gps_dia(p_dia date) returns int
language plpgsql security definer set search_path = public as $$
declare a timestamptz := (p_dia::timestamp at time zone 'America/Belem'); n int;
begin
  insert into samples_gps (device_id, frota, ts, lat, lon, speed_kmh)
  select device_id, public.normaliza_tag(device_name), ts, lat, lon, speed_kmh
  from (select s.*, row_number() over (partition by s.device_id, date_trunc('hour', s.ts),
                                         floor(extract(minute from s.ts) / 5) order by s.ts) as rn
        from samples s
        where s.ts >= a and s.ts < a + interval '1 day'
          and s.lat is not null and s.lon is not null and not (s.lat = 0 and s.lon = 0)) x
  where coalesce(speed_kmh, 0) >= 3 or rn = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public._arq_gps_dia(date) from public, anon, authenticated;

-- ---------------------------------------------------------------- limpeza diária (substitui a de limpeza-amostras.sql)
create or replace function public.manutencao_samples(p_dias integer default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cfg    arq_config;
  hoje   date := (now() at time zone 'America/Belem')::date;
  dias   int;
  corte  date;       -- dias ANTES disso saem do Supabase (se arquivados)
  teto   date;       -- dias antes disso saem mesmo sem arquivo
  minc   integer := coalesce((select nullif(config->>'min_current_ma','')::int from device_config where device_id = '*'), 300);
  d date; n_res int := 0; n_gps int := 0; k int; n_amo int := 0; n_gps_del int := 0; sem_arq date[] := '{}';
begin
  select * into cfg from arq_config where id = 1;
  dias  := greatest(coalesce(p_dias, cfg.dias_supabase), 2);
  corte := hoje - dias + 1;
  teto  := hoje - greatest(cfg.teto_dias, dias) + 1;

  -- 1) resumo por dia (dias completos que ainda têm todas as amostras)
  insert into samples_dia as s (dia, device_id, device_name, amostras, min_tomada, min_carga_fraca,
         bateria_min, bateria_max, min_hotspot, min_bluetooth, pontos_rota, dados_moveis_mb, hotspot_mb,
         primeira, ultima, atualizado_em)
  select a.dia, a.device_id, max(a.device_name), count(*),
         count(*) filter (where a.plugged),
         count(*) filter (where a.plugged and a.current_ma is not null and a.current_ma < minc),
         min(a.battery_pct), max(a.battery_pct),
         count(*) filter (where a.hotspot_on), count(*) filter (where a.bt_on),
         count(*) filter (where a.speed_kmh >= 3),
         round(max(a.mobile_bytes_today) / 1e6, 1), round(max(a.tether_bytes_today) / 1e6, 1),
         min(a.ts), max(a.ts), now()
  from (select (ts at time zone 'America/Belem')::date as dia, * from samples
        where ts >= ((hoje - 3)::timestamp at time zone 'America/Belem')
           or ts < (corte::timestamp at time zone 'America/Belem')) a
  where a.dia < hoje
  group by a.dia, a.device_id
  having a.dia >= hoje - 3
      or not exists (select 1 from samples_dia x where x.dia = a.dia and x.device_id = a.device_id)
  on conflict (dia, device_id) do update set
    device_name = excluded.device_name, amostras = excluded.amostras, min_tomada = excluded.min_tomada,
    min_carga_fraca = excluded.min_carga_fraca, bateria_min = excluded.bateria_min, bateria_max = excluded.bateria_max,
    min_hotspot = excluded.min_hotspot, min_bluetooth = excluded.min_bluetooth, pontos_rota = excluded.pontos_rota,
    dados_moveis_mb = excluded.dados_moveis_mb, hotspot_mb = excluded.hotspot_mb,
    primeira = excluded.primeira, ultima = excluded.ultima, atualizado_em = now();
  get diagnostics n_res = row_count;

  -- 2) GPS enxuto: ontem e anteontem (recalcula) + qualquer dia que vai sair e ainda não tem
  for d in select x::date from generate_series(
             least((select (min(ts) at time zone 'America/Belem')::date from samples), hoje - 2), hoje - 1, interval '1 day') x
  loop
    if d >= hoje - 2 or not exists (select 1 from samples_gps g where g.ts >= (d::timestamp at time zone 'America/Belem')
                                      and g.ts < ((d + 1)::timestamp at time zone 'America/Belem')) then
      k := _arq_gps_dia(d); n_gps := n_gps + k;
    end if;
  end loop;

  -- 3) apaga do Supabase os dias antigos já arquivados (ou além do teto), guardando a última leitura de cada celular
  create temp table if not exists _arq_ultimas (id bigint primary key) on commit drop;
  truncate _arq_ultimas;
  insert into _arq_ultimas select distinct on (device_id) id from samples order by device_id, ts desc;
  for d in select x::date from generate_series(
             (select (min(ts) at time zone 'America/Belem')::date from samples), corte - 1, interval '1 day') x
  loop
    if exists (select 1 from samples_arquivo a where a.dia = d) or d < teto then
      if d < teto and not exists (select 1 from samples_arquivo a where a.dia = d) then sem_arq := sem_arq || d; end if;
      delete from samples s
       where s.ts >= (d::timestamp at time zone 'America/Belem') and s.ts < ((d + 1)::timestamp at time zone 'America/Belem')
         and not exists (select 1 from _arq_ultimas u where u.id = s.id);
      get diagnostics k = row_count; n_amo := n_amo + k;
    end if;
  end loop;

  -- 4) GPS enxuto mais velho que dias_gps
  delete from samples_gps where ts < ((hoje - cfg.dias_gps)::timestamp at time zone 'America/Belem');
  get diagnostics n_gps_del = row_count;

  insert into arq_log (resultado) values (jsonb_build_object('dias_resumidos', n_res, 'gps_gravados', n_gps,
    'amostras_apagadas', n_amo, 'gps_apagados', n_gps_del, 'apagados_sem_arquivo', sem_arq,
    'supabase_desde', corte));
  return (select resultado from arq_log order by id desc limit 1);
end $$;
revoke execute on function public.manutencao_samples(integer) from public, anon, authenticated;

-- agenda: 06:30 UTC = 03:30 em Belém (substitui a anterior, mesmo nome)
select cron.unschedule(jobid) from cron.job where jobname = 'limpeza-amostras';
select cron.schedule('limpeza-amostras', '30 6 * * *', 'select public.manutencao_samples()');

-- ---------------------------------------------------------------- robô do Drive (mesma chave do quadro de Demandas)
create or replace function public._arq_chave(p_chave text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
end $$;
revoke execute on function public._arq_chave(text) from public, anon, authenticated;

-- dias completos (antes de hoje) que ainda têm amostras no Supabase e não estão no Drive
create or replace function public.arq_pendentes(p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare hoje date := (now() at time zone 'America/Belem')::date; ini date;
begin
  perform _arq_chave(p_chave);
  select (min(ts) at time zone 'America/Belem')::date into ini from samples;
  return json_build_object('pasta', (select pasta_drive from arq_config where id = 1),
    'dias', coalesce((select json_agg(d order by d) from (
        select x::date as d from generate_series(ini, hoje - 1, interval '1 day') x
        where not exists (select 1 from samples_arquivo a where a.dia = x::date)
          and (select count(*) from (select 1 from samples s where s.ts >= (x::date::timestamp at time zone 'America/Belem')
                 and s.ts < ((x::date + 1)::timestamp at time zone 'America/Belem') limit 2) z) > 1) q), '[]'::json));
end $$;

-- uma página de leituras do dia (ordem ts, id), devolve as linhas inteiras em JSON
create or replace function public.arq_pagina(p_chave text, p_dia date, p_depois timestamptz default null,
  p_depois_id bigint default 0, p_limite int default 3000) returns json
language plpgsql security definer set search_path = public as $$
declare a timestamptz := (p_dia::timestamp at time zone 'America/Belem');
begin
  perform _arq_chave(p_chave);
  return (select json_build_object('linhas', coalesce(json_agg(to_jsonb(s) order by s.ts, s.id), '[]'::json),
            'ultimo_ts', max(s.ts), 'ultimo_id', (array_agg(s.id order by s.ts desc, s.id desc))[1], 'qtd', count(*))
    from (select * from samples
          where ts >= coalesce(p_depois, a) and ts < a + interval '1 day'
            and (p_depois is null or ts > p_depois or (ts = p_depois and id > p_depois_id))
          order by ts, id limit least(greatest(p_limite, 100), 6000)) s);
end $$;

create or replace function public.arq_marcar(p_chave text, p_dia date, p_linhas int, p_bytes bigint, p_arquivo_id text, p_link text) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform _arq_chave(p_chave);
  if coalesce(p_linhas, 0) < 1 or coalesce(p_arquivo_id, '') = '' then raise exception 'Arquivo vazio, não marquei.'; end if;
  insert into samples_arquivo (dia, linhas, bytes, arquivo_id, link) values (p_dia, p_linhas, p_bytes, p_arquivo_id, p_link)
  on conflict (dia) do update set linhas = excluded.linhas, bytes = excluded.bytes, arquivo_id = excluded.arquivo_id,
    link = excluded.link, arquivado_em = now();
  return 'ok';
end $$;

-- ---------------------------------------------------------------- página de consulta (senha da Central, painel Monitor)
create or replace function public._arq_quem(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a central_acessos;
begin
  if p_token like 'tfs_%' then
    select * into a from public._central_pessoa(p_token);
    if a.id is not null and (public._central_pode(a, 'monitor', 'ver') or public._central_pode(a, 'bi', 'ver')) then
      return jsonb_build_object('nome', a.nome, 'admin', a.admin);
    end if;
  elsif p_token like 'tfg_%' then
    if exists (select 1 from sol_sessoes_gestor where token = p_token and expira_em > now()) then
      return jsonb_build_object('nome', 'Senha de gestores', 'admin', true);
    end if;
  end if;
  raise exception 'sessao';
end $$;
revoke execute on function public._arq_quem(text) from public, anon, authenticated;

create or replace function public.hist_entrar(p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'historico'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is not null and (public._central_pode(a, 'monitor', 'ver') or public._central_pode(a, 'bi', 'ver')) then
    tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
    insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
    perform public._central_log(a.id, a.nome, 'entrou', 'historico', 'Entrou no Histórico do Monitor');
    return json_build_object('token', tk, 'nome', a.nome);
  end if;
  if exists (select 1 from lotacao_admin where id = 1 and senha_hash = crypt(trim(p_senha), senha_hash)) then
    tk := 'tfg_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes_gestor (token, expira_em) values (tk, now() + interval '30 days');
    return json_build_object('token', tk, 'nome', 'Senha de gestores');
  end if;
  perform public._central_log(null, null, 'senha_errada', 'historico', 'Senha errada no Histórico');
  return json_build_object('erro', 'Senha não encontrada ou sem acesso ao Monitor.');
end $$;

-- resumo: dias arquivados, uso do banco, resumo por carro/dia no período
create or replace function public.hist_inicio(p_token text, p_de date, p_ate date) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := _arq_quem(p_token);
begin
  if p_ate - p_de > 92 then raise exception 'Escolha até 3 meses.'; end if;
  return json_build_object('quem', q,
    'config', (select to_jsonb(c) from arq_config c where id = 1),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0),
    'samples_mb', round(pg_total_relation_size('public.samples') / 1048576.0),
    'gps_mb', round(pg_total_relation_size('public.samples_gps') / 1048576.0),
    'supabase_desde', (select (min(ts) at time zone 'America/Belem')::date from samples where ts > now() - interval '30 days'),
    'gps_desde', (select (min(ts) at time zone 'America/Belem')::date from samples_gps),
    'ultima_limpeza', (select json_build_object('ts', ts, 'resultado', resultado) from arq_log order by id desc limit 1),
    'arquivos', (select coalesce(json_agg(json_build_object('dia', dia, 'linhas', linhas, 'mb', round(bytes / 1048576.0, 1),
                   'link', link, 'em', arquivado_em) order by dia desc), '[]'::json) from samples_arquivo),
    'dias', (select coalesce(json_agg(json_build_object('dia', s.dia, 'carro', coalesce(public.normaliza_tag(s.device_name), s.device_name),
                   'amostras', s.amostras, 'min_tomada', s.min_tomada, 'min_carga_fraca', s.min_carga_fraca,
                   'bat_min', s.bateria_min, 'bat_max', s.bateria_max, 'min_hotspot', s.min_hotspot, 'min_bt', s.min_bluetooth,
                   'pontos_rota', s.pontos_rota, 'dados_mb', s.dados_moveis_mb, 'hotspot_mb', s.hotspot_mb,
                   'primeira', s.primeira, 'ultima', s.ultima) order by s.dia desc, s.device_name), '[]'::json)
             from samples_dia s where s.dia between p_de and p_ate));
end $$;

-- trajeto de um carro num dia: GPS completo se ainda estiver no Supabase, senão o enxuto
create or replace function public.hist_trajeto(p_token text, p_carro text, p_dia date) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := _arq_quem(p_token); a timestamptz := (p_dia::timestamp at time zone 'America/Belem'); f text := public.normaliza_tag(p_carro);
  r json;
begin
  select json_agg(json_build_object('ts', ts, 'lat', lat, 'lon', lon, 'v', speed_kmh) order by ts) into r
    from samples where ts >= a and ts < a + interval '1 day' and lat is not null and lon is not null and not (lat = 0 and lon = 0)
     and public.normaliza_tag(device_name) = f;
  if r is not null then return json_build_object('fonte', 'completo', 'pontos', r); end if;
  select json_agg(json_build_object('ts', ts, 'lat', lat, 'lon', lon, 'v', speed_kmh) order by ts) into r
    from samples_gps where frota = f and ts >= a and ts < a + interval '1 day';
  return json_build_object('fonte', case when r is null then 'nenhum' else 'enxuto' end, 'pontos', coalesce(r, '[]'::json));
end $$;

grant execute on function public.arq_pendentes(text), public.arq_pagina(text, date, timestamptz, bigint, int),
  public.arq_marcar(text, date, int, bigint, text, text), public.hist_entrar(text), public.hist_inicio(text, date, date),
  public.hist_trajeto(text, text, date) to anon, authenticated;

notify pgrst, 'reload schema';
select 'Arquivo das amostras pronto (nada foi apagado)' as status,
  (select count(*) from public.samples_arquivo) as dias_no_drive,
  pg_size_pretty(pg_total_relation_size('public.samples')) as samples_hoje;
