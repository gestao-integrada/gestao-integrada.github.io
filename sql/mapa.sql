-- =====================================================================================================
-- MAPA AO VIVO DA FROTA  (página gestao-integrada.github.io/mapa/)
-- Usa o que já existe: samples (GPS do Monitor), viagens (coleta TFleet), rotas_tracado (traçado das rotas),
-- bi_cercas (cercas do BI) e o login do BI/Central (_bi_exige). Não cria tabela nova.
-- Rodar DEPOIS de sql/bi.sql. Pode rodar de novo sem problema.
-- =====================================================================================================

-- limites do mapa (editáveis depois por UPDATE em bi_config)
alter table public.bi_config add column if not exists mapa_sem_sinal_min int not null default 15;  -- sem posição há mais que isso = SEM SINAL
alter table public.bi_config add column if not exists mapa_tol_atraso_min int not null default 5;  -- passou do previsto + isso = ATRASADO
alter table public.bi_config add column if not exists mapa_ideal int not null default 40;          -- acima disso = CHEIO; >= lugares = LOTADO

-- Situação de cada ônibus agora: última posição do Monitor + viagem aberta na TFleet.
-- estado: sem_sinal (só quem tem Monitor) > atrasado > lotado > cheio > ok (> sem_viagem quando não tem viagem aberta)
create or replace function public.mapa_frota(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  q jsonb := public._bi_exige(p_token);
  c bi_config;
begin
  select * into c from bi_config where id = 1;
  return json_build_object(
    'agora', now(),
    'config', json_build_object('sem_sinal_min', c.mapa_sem_sinal_min, 'tol_atraso_min', c.mapa_tol_atraso_min,
                                'ideal', c.mapa_ideal, 'lugares', c.lugares),
    'onibus', (
      with pos as (   -- última posição de cada celular nas últimas 24 h
        select distinct on (s.device_id) public.normaliza_tag(s.device_name) as frota, s.device_name, s.ts,
               s.lat::float8 as lat, s.lon::float8 as lon, s.speed_kmh, s.battery_pct, s.plugged
        from samples s
        where s.ts > now() - interval '24 hours' and s.lat is not null and s.lon is not null and not (s.lat = 0 and s.lon = 0)
        order by s.device_id, s.ts desc),
      pos1 as (select distinct on (frota) * from pos where frota is not null order by frota, ts desc),
      via as (        -- viagem aberta (ou fechada há menos de 20 min) de cada ônibus
        select distinct on (public.normaliza_tag(v.frota)) public.normaliza_tag(v.frota) as frota,
               v.id, v.placa, v.empresa, v.tipolinha, v.linha, v.tipo, v.motorista, v.saida_ts, v.chegada_ts, v.ocupacao,
               v.data_local, v.hora_saida,
               substring(case when upper(v.tipo) = 'VOLTA' then v.bruto->>'saidaprevista' else v.bruto->>'entradaprevista' end
                         from '(\d{1,2}:\d{2})') as prev
        from viagens v
        where v.saida_ts > now() - interval '8 hours' and (v.chegada_ts is null or v.chegada_ts > now() - interval '20 minutes')
          and public.normaliza_tag(v.frota) is not null
        order by public.normaliza_tag(v.frota), (v.chegada_ts is null) desc, v.saida_ts desc),
      via2 as (       -- previsto em timestamp (Belém); IDA que vira a meia-noite passa p/ o dia seguinte
        select via.*,
               case when prev is null then null
                    else ((data_local + (case when upper(tipo) <> 'VOLTA' and prev::time < hora_saida - interval '1 hour'
                                              then 1 else 0 end)) + prev::time) at time zone 'America/Belem' end as prev_ts
        from via),
      via3 as (
        select via2.*,
               case when prev_ts is null then null
                    when upper(tipo) = 'VOLTA' then round(extract(epoch from saida_ts - prev_ts) / 60)       -- saiu quantos min depois do previsto
                    when chegada_ts is null then round(extract(epoch from now() - prev_ts) / 60)           -- IDA aberta: quanto passou do previsto
                    else round(extract(epoch from chegada_ts - prev_ts) / 60) end as atraso_min
        from via2),
      tudo as (
        select coalesce(p.frota, v.frota) as frota, p.device_name, p.ts, p.lat, p.lon, p.speed_kmh, p.battery_pct, p.plugged,
               round(extract(epoch from now() - p.ts) / 60) as idade_min,
               v.id as viagem_id, v.placa, v.empresa, v.tipolinha, v.linha, v.tipo, v.motorista, v.saida_ts, v.chegada_ts,
               v.ocupacao, v.prev, v.prev_ts, v.atraso_min
        from pos1 p full join via3 v on v.frota = p.frota)
      select coalesce(json_agg(json_build_object(
               'frota', frota, 'aparelho', device_name, 'ts', ts, 'lat', lat, 'lon', lon, 'kmh', round(speed_kmh::numeric),
               'bateria', battery_pct, 'tomada', plugged, 'idade_min', idade_min,
               'viagem', viagem_id, 'placa', placa, 'empresa', empresa, 'turno', tipolinha, 'linha', linha, 'sentido', tipo,
               'motorista', motorista, 'saida', saida_ts, 'chegada', chegada_ts, 'ocupacao', ocupacao, 'previsto', prev,
               'atraso_min', atraso_min,
               'estado', case
                  when ts is not null and idade_min > c.mapa_sem_sinal_min then 'sem_sinal'
                  when viagem_id is null then 'sem_viagem'
                  when atraso_min > c.mapa_tol_atraso_min and (chegada_ts is null or upper(tipo) = 'VOLTA') then 'atrasado'
                  when ocupacao >= c.lugares then 'lotado'
                  when ocupacao > c.mapa_ideal then 'cheio'
                  else 'ok' end) order by frota), '[]'::json)
      from tudo),
    'cercas', (select coalesce(json_agg(json_build_object('nome', nome, 'cor', cor, 'finalidade', finalidade, 'pontos', pontos)
                                        order by nome), '[]'::json)
               from bi_cercas where ativo and jsonb_array_length(pontos) >= 3));
end $$;

-- traçado das rotas (sem nomes de passageiros). p_linha null = todas
create or replace function public.mapa_tracado(p_token text, p_linha text default null, p_sentido text default null)
returns json language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  if to_regclass('public.rotas_tracado') is null then return '[]'::json; end if;
  return (select coalesce(json_agg(json_build_object('linha', linha, 'sentido', sentido, 'turno', tipolinha,
                                                     'pontos', pontos, 'paradas', paradas, 'km', km)), '[]'::json)
          from rotas_tracado
          where jsonb_array_length(pontos) > 1
            and (p_linha is null or linha_norm = public.norm_linha(regexp_replace(p_linha, '\s+', ' ', 'g')))
            and (p_sentido is null or upper(sentido) = upper(p_sentido)));
end $$;

grant execute on function public.mapa_frota(text), public.mapa_tracado(text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';
