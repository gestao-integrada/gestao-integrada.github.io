-- GPS enxuto mais leve: 1 ponto a cada 5 min por celular (antes guardava todo minuto em movimento = quase tudo),
-- guarda 30 dias (antes 90) e tira um índice. Refaz a tabela a partir das leituras que estão no Supabase.
-- O arquivo completo de cada dia continua indo para o Google Drive.
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
  where rn = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public._arq_gps_dia(date) from public, anon, authenticated;

update public.arq_config set dias_gps = 30 where id = 1;
drop index if exists public.samples_gps_ts;
truncate public.samples_gps;

set statement_timeout = '10min';
select d::date as dia, public._arq_gps_dia(d::date) as pontos
from generate_series(((now() at time zone 'America/Belem')::date - 7), (now() at time zone 'America/Belem')::date, interval '1 day') d;
