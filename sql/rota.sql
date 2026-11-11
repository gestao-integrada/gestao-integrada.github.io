-- App de apoio da rota (piloto Jd. Bela Vista)
-- Grava a chegada do ônibus em cada ponto (cerca) e permite ler no painel.
-- Sem nomes de pessoas: só rota, ônibus, ponto e horários.
-- Rodar inteiro no Supabase → SQL Editor. Pode rodar de novo sem problema.

create table if not exists rota_passagens (
  id          bigserial primary key,
  criado_em   timestamptz not null default now(),
  viagem      text not null,
  data        date not null,
  rota        text not null,
  rota_nome   text,
  onibus      text,
  ponto_seq   int  not null,
  ponto_nome  text,
  previsto    text,
  tipo        text not null check (tipo in ('chegou','nao_passou')),
  chegada     timestamptz,
  atraso_min  int,
  simulacao   boolean not null default false,
  unique (viagem, ponto_seq)
);
create index if not exists rota_passagens_data on rota_passagens (data, rota);

alter table rota_passagens enable row level security;
-- sem políticas: ninguém lê/escreve direto; só pelas funções abaixo
revoke all on rota_passagens from anon, authenticated;

-- grava uma lista de passagens (o app manda a fila de uma vez)
create or replace function rota_registrar(p_itens jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; i jsonb;
begin
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) > 200 then
    raise exception 'lista inválida';
  end if;
  for i in select * from jsonb_array_elements(p_itens) loop
    insert into rota_passagens (viagem, data, rota, rota_nome, onibus, ponto_seq, ponto_nome, previsto, tipo, chegada, atraso_min, simulacao)
    values (left(i->>'viagem',60), (i->>'data')::date, left(i->>'rota',60), left(i->>'rota_nome',120), left(i->>'onibus',20),
            (i->>'ponto_seq')::int, left(i->>'ponto_nome',120), left(i->>'previsto',5), i->>'tipo',
            nullif(i->>'chegada','')::timestamptz, nullif(i->>'atraso_min','')::int, coalesce((i->>'simulacao')::boolean,false))
    on conflict (viagem, ponto_seq) do update
      set tipo = excluded.tipo, chegada = excluded.chegada, atraso_min = excluded.atraso_min, onibus = excluded.onibus;
    n := n + 1;
  end loop;
  return n;
end $$;

-- leitura para o painel (um dia, todas as rotas ou uma)
create or replace function rota_listar(p_data date, p_rota text default null, p_simulacao boolean default false)
returns setof rota_passagens language sql security definer set search_path = public as $$
  select * from rota_passagens
  where data = p_data and (p_rota is null or rota = p_rota) and (p_simulacao or not simulacao)
  order by rota, viagem, ponto_seq;
$$;

revoke all on function rota_registrar(jsonb) from public;
revoke all on function rota_listar(date, text, boolean) from public;
grant execute on function rota_registrar(jsonb) to anon, authenticated;
grant execute on function rota_listar(date, text, boolean) to anon, authenticated;

-- ===== Posição ao vivo (para acompanhar o ônibus de outro celular) =====
create table if not exists rota_posicao (
  aparelho  text primary key,
  rota      text not null,
  onibus    text,
  viagem    text,
  lat       double precision not null,
  lon       double precision not null,
  vel       int,
  precisao  int,
  em        timestamptz not null,
  simulacao boolean not null default false
);
alter table rota_posicao enable row level security;
revoke all on rota_posicao from anon, authenticated;

create or replace function rota_posicao_enviar(p jsonb)
returns void language sql security definer set search_path = public as $$
  insert into rota_posicao (aparelho, rota, onibus, viagem, lat, lon, vel, precisao, em, simulacao)
  values (left(p->>'aparelho',40), left(p->>'rota',60), left(p->>'onibus',20), left(p->>'viagem',60),
          (p->>'lat')::float8, (p->>'lon')::float8, nullif(p->>'vel','')::int, nullif(p->>'precisao','')::int,
          least(coalesce((p->>'em')::timestamptz, now()), now() + interval '1 day'), coalesce((p->>'simulacao')::boolean,false))
  on conflict (aparelho) do update set rota = excluded.rota, onibus = excluded.onibus, viagem = excluded.viagem,
    lat = excluded.lat, lon = excluded.lon, vel = excluded.vel, precisao = excluded.precisao, em = excluded.em, simulacao = excluded.simulacao;
$$;

-- última posição da rota (enviada nas últimas 12 horas)
create or replace function rota_posicao_ultima(p_rota text, p_simulacao boolean default false)
returns setof rota_posicao language sql security definer set search_path = public as $$
  select * from rota_posicao
  where rota = p_rota and simulacao = p_simulacao and em > now() - interval '12 hours'
  order by em desc limit 1;
$$;

revoke all on function rota_posicao_enviar(jsonb) from public;
revoke all on function rota_posicao_ultima(text, boolean) from public;
grant execute on function rota_posicao_enviar(jsonb) to anon, authenticated;
grant execute on function rota_posicao_ultima(text, boolean) to anon, authenticated;
