-- =====================================================================
-- BI DA FROTA (página gestao-integrada.github.io/bi/)
-- Os mesmos painéis do Power BI "Base automática T-FLEET", lendo o nosso Supabase:
--   Ocupação · Fora de rota · Horários de entrada e saída · Viagens por dia · Custo por pessoa · Não cadastrados
-- Diferenças de propósito em relação ao .pbix:
--   - nada de horário sorteado: sem hora = "sem dado";
--   - entrada/saída medida pelas CERCAS (polígonos) com o GPS do app Monitor (tabela samples, 1 posição/min);
--     sem Monitor no carro, usa a hora da TFleet (hrsla na IDA, abertura na VOLTA) e diz de onde veio;
--   - lugares por ônibus e valor por pessoa ficam em bi_config (editáveis), não fixos no código.
-- Quem entra: senha pessoal da Central (admin, ou marcado em "bi" ou "lotacao") ou a senha de gestores.
-- Quem edita (gerenciar painéis, cercas, ajustes): admin, "bi: editar" ou senha de gestores.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo.
-- Depende de: lotacao.sql (viagens, embarques, lotacao_admin), central-acessos.sql, solicitacoes.sql
-- (sol_sessoes_gestor), schema.sql + atualizacao-rota.sql do Monitor (samples com lat/lon) e
-- whatsapp/ocorrencias.sql (normaliza_tag).
-- =====================================================================

-- ---------------------------------------------------------------- tabelas
create table if not exists public.bi_config (
  id            int primary key default 1 check (id = 1),
  lugares       int not null default 45,            -- lugares por ônibus (ocupação %)
  valor_pessoa  numeric(10,2) not null default 40.90, -- R$ por embarque (custo por pessoa)
  gap_min       int not null default 5,             -- buraco maior que isso entre 2 posições = horário incerto
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
insert into public.bi_config (id) values (1) on conflict (id) do nothing;
-- turnos acompanhados em "Viagens por dia" e a meta (ideal) de viagens por dia de cada um
alter table public.bi_config add column if not exists viagens_turnos text[] not null default '{ADM,TURNO 01 12X12,TURNO 02 12X12}';
alter table public.bi_config add column if not exists viagens_ideal jsonb not null default '{}'::jsonb;   -- {"ADM": 60, ...}
-- áreas onde um ponto de embarque é válido (fora delas = GPS errado: Parauapebas, Canaã, mar...)
alter table public.bi_config add column if not exists areas jsonb not null default
  '[{"nome":"Paragominas e mina","lat_min":-3.80,"lat_max":-2.55,"lon_min":-48.10,"lon_max":-46.90},
    {"nome":"Quatro Bocas e Tomé-Açu","lat_min":-2.90,"lat_max":-2.00,"lon_min":-48.80,"lon_max":-47.90}]'::jsonb;

-- ponto dentro de alguma das áreas válidas
create or replace function public._bi_na_area(la float8, lo float8, areas jsonb) returns boolean
language sql immutable as $$
  select la is not null and lo is not null and exists (select 1 from jsonb_array_elements(coalesce(areas, '[]'::jsonb)) a
    where la between (a->>'lat_min')::float8 and (a->>'lat_max')::float8 and lo between (a->>'lon_min')::float8 and (a->>'lon_max')::float8);
$$;

-- painéis da página: situacao todos = todo mundo que entra vê; admin = só quem edita; excluido = some (restaurável)
create table if not exists public.bi_paineis (
  id            text primary key,
  titulo        text not null,
  descricao     text,
  ordem         int not null default 0,
  situacao      text not null default 'todos' check (situacao in ('todos', 'admin', 'excluido')),
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
insert into public.bi_paineis (id, titulo, descricao, ordem) values
  ('ocupacao',   'Ocupação',                     'Pessoas transportadas por linha e por dia, ocupação dos ônibus e status dos passageiros.', 1),
  ('horarios',   'Horários de entrada e saída',  'Chegada e saída de cada viagem nas cercas dos turnos, comparadas com o horário previsto e a tolerância.', 2),
  ('fora_rota',  'Fora de rota',                 'Passageiros que embarcaram numa linha diferente da linha de cadastro, e os não regulares.', 3),
  ('viagens',    'Viagens por dia',              'Quantas viagens foram abertas por dia em cada turno e a média do período.', 4),
  ('custo',      'Custo por pessoa',             'Embarques vezes o valor por pessoa, por gerência, turno e linha.', 5),
  ('nao_cad',    'Não cadastrados',              'Itinerantes e passageiros não cadastrados, com o crachá lido para consulta.', 6)
on conflict (id) do nothing;

-- cercas: polígono + regras de horário. horarios = [{rotulo, tipolinhas[], linha_contem, chegada "07:40",
--   cheg_antes, cheg_depois, saida "17:00", sai_antes, sai_depois, dias[1..7 seg..dom]}]
create table if not exists public.bi_cercas (
  id            bigserial primary key,
  nome          text not null,
  turno         text,
  cor           text not null default '#2563eb',
  pontos        jsonb not null default '[]'::jsonb,  -- [[lat, lon], ...]
  poly          float8[] not null default '{}',      -- lat1, lon1, lat2, lon2, ... (preenchido ao salvar)
  lat_min float8, lat_max float8, lon_min float8, lon_max float8,
  horarios      jsonb not null default '[]'::jsonb,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);

-- entradas e saídas já calculadas (cache por cerca + dia de Belém)
-- para que serve a cerca: turno = entrada e saída do turno (usada no painel Horários);
-- terminal = chegada e saída do terminal; fim_rota = fim das rotas; outra. As outras finalidades já guardam
-- as entradas e saídas e entram em painéis próprios depois.
alter table public.bi_cercas add column if not exists finalidade text not null default 'turno';
alter table public.bi_cercas drop constraint if exists bi_cercas_finalidade_check;
alter table public.bi_cercas add constraint bi_cercas_finalidade_check check (finalidade in ('turno', 'terminal', 'fim_rota', 'outra'));

create table if not exists public.bi_cerca_eventos (
  cerca_id  bigint not null references public.bi_cercas(id) on delete cascade,
  dia       date not null,
  frota     text not null,
  device_id text not null,
  tipo      text not null check (tipo in ('entrada', 'saida')),
  ts        timestamptz not null,
  gap_min   numeric,            -- minutos desde a posição anterior (incerteza do horário)
  primary key (cerca_id, device_id, tipo, ts)
);
create index if not exists bi_cerca_eventos_busca on public.bi_cerca_eventos (cerca_id, frota, tipo, ts);
create table if not exists public.bi_cerca_dias (
  cerca_id      bigint not null references public.bi_cercas(id) on delete cascade,
  dia           date not null,
  processado_em timestamptz not null default now(),
  frotas        text[] not null default '{}',   -- carros que mandaram posição nesse dia (tinham Monitor)
  primary key (cerca_id, dia)
);

alter table public.bi_config        enable row level security;
alter table public.bi_paineis       enable row level security;
alter table public.bi_cercas        enable row level security;
alter table public.bi_cerca_eventos enable row level security;
alter table public.bi_cerca_dias    enable row level security;
revoke all on public.bi_config, public.bi_paineis, public.bi_cercas, public.bi_cerca_eventos, public.bi_cerca_dias
  from anon, authenticated;

-- ---------------------------------------------------------------- utilidades
create or replace function public._bi_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Belem')::date $$;

-- ponto dentro do polígono (raio cruzando as arestas); p = lat1, lon1, lat2, lon2, ...
create or replace function public._bi_dentro(la float8, lo float8, p float8[]) returns boolean
language plpgsql immutable as $$
declare n int := coalesce(array_length(p, 1), 0) / 2; i int; j int; yi float8; xi float8; yj float8; xj float8; d boolean := false;
begin
  if n < 3 or la is null or lo is null then return false; end if;
  j := n;
  for i in 1..n loop
    yi := p[2*i-1]; xi := p[2*i]; yj := p[2*j-1]; xj := p[2*j];
    if ((yi > la) <> (yj > la)) and (lo < (xj - xi) * (la - yi) / (yj - yi) + xi) then d := not d; end if;
    j := i;
  end loop;
  return d;
end $$;

-- viagens sem repetição (se a TFleet corrigiu a viagem, vale a versão mais nova), como em aberturas.sql
create or replace function public._bi_viagens(p_de date, p_ate date)
returns setof public.viagens
language sql stable security definer set search_path = public as $$
  select distinct on (coalesce(x.frota, x.placa), x.saida_ts) x.*
  from viagens x
  where x.data_local between p_de and p_ate
  order by coalesce(x.frota, x.placa), x.saida_ts, x.coletado_em desc;
$$;

-- empresa como no .pbix (junta as variações da Hydro)
create or replace function public._bi_empresa(e text) returns text
language sql immutable as $$
  select nullif(trim(replace(replace(replace(replace(upper(coalesce(e, '')),
    'MINERAÇÃO PARAGOMINAS', 'HYDRO'), 'HYDRO PARAGOMINAS', 'HYDRO'), ' E SERVICOS (HYDRO)', ''), ' - PARAGOMINAS', '')), '');
$$;

-- "07:40" → minutos do dia
create or replace function public._bi_min(t text) returns int
language sql immutable as $$
  select case when t ~ '^\d{1,2}:\d{2}' then split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int end;
$$;

-- ---------------------------------------------------------------- quem está usando
create or replace function public._bi_quem(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a central_acessos;
begin
  if p_token like 'tfs_%' then
    select * into a from public._central_pessoa(p_token);
    if a.id is not null and (public._central_pode(a, 'bi', 'ver') or public._central_pode(a, 'lotacao', 'ver')) then
      update central_sessoes set ultimo_uso = now() where token = p_token;
      return jsonb_build_object('nome', a.nome, 'acesso_id', a.id, 'admin', a.admin,
                                'edita', public._central_pode(a, 'bi', 'editar'));
    end if;
  elsif p_token like 'tfg_%' then
    if exists (select 1 from sol_sessoes_gestor where token = p_token and expira_em > now()) then
      return jsonb_build_object('nome', 'Senha de gestores', 'acesso_id', null, 'admin', true, 'edita', true);
    end if;
  end if;
  return null;
end $$;

create or replace function public._bi_exige(p_token text, p_editar boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_quem(p_token);
begin
  if q is null then raise exception 'sessao'; end if;
  if p_editar and not (q->>'edita')::boolean then raise exception 'Você pode ver o BI, mas não alterar.'; end if;
  return q;
end $$;
revoke execute on function public._bi_quem(text), public._bi_exige(text, boolean), public._bi_viagens(date, date)
  from public, anon, authenticated;

create or replace function public.bi_entrar(p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a central_acessos; tk text;
begin
  if (select count(*) from central_acessos_log where evento = 'senha_errada' and painel = 'bi'
      and ts > now() - interval '10 minutes') >= 30 then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos.');
  end if;
  select * into a from central_acessos where senha_hash = public._central_hash(trim(p_senha)) and ativo;
  if a.id is not null then
    if not (public._central_pode(a, 'bi', 'ver') or public._central_pode(a, 'lotacao', 'ver')) then
      return json_build_object('erro', 'Sua senha não tem acesso ao BI. Peça para liberar o painel BI na Gestão de acessos.');
    end if;
    tk := 'tfs_' || encode(gen_random_bytes(24), 'hex');
    insert into central_sessoes (token, acesso_id, expira_em) values (tk, a.id, now() + interval '30 days');
    perform public._central_log(a.id, a.nome, 'entrou', 'bi', 'Entrou no BI');
    return (jsonb_build_object('token', tk) || public._bi_quem(tk))::json;
  end if;
  if exists (select 1 from lotacao_admin where id = 1 and senha_hash = crypt(trim(p_senha), senha_hash)) then
    tk := 'tfg_' || encode(gen_random_bytes(24), 'hex');
    insert into sol_sessoes_gestor (token, expira_em) values (tk, now() + interval '30 days');
    perform public._central_log(null, 'Senha de gestores', 'entrou', 'bi', 'Entrou no BI');
    return (jsonb_build_object('token', tk) || public._bi_quem(tk))::json;
  end if;
  perform public._central_log(null, null, 'senha_errada', 'bi', 'Senha errada no BI');
  return json_build_object('erro', 'Senha não encontrada.');
end $$;

create or replace function public.bi_sessao(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_quem(p_token);
begin
  if q is null then return json_build_object('erro', 'sessao'); end if;
  return q::json;
end $$;

create or replace function public.bi_sair(p_token text) returns text
language plpgsql security definer set search_path = public as $$
begin
  delete from sol_sessoes_gestor where token = p_token and p_token like 'tfg_%';
  return 'ok';   -- sessão da Central continua valendo na Central
end $$;

-- ---------------------------------------------------------------- painéis e ajustes
create or replace function public.bi_inicio(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); ed boolean := (q->>'edita')::boolean;
begin
  return json_build_object(
    'quem', q,
    'paineis', (select coalesce(json_agg(json_build_object('id', id, 'titulo', titulo, 'descricao', descricao,
                   'ordem', ordem, 'situacao', situacao, 'atualizado_por', atualizado_por, 'atualizado_em', atualizado_em)
                 order by ordem, id), '[]'::json)
                from bi_paineis where situacao = 'todos' or (ed and situacao in ('admin', 'excluido'))),
    'config', (select json_build_object('lugares', lugares, 'valor_pessoa', valor_pessoa, 'gap_min', gap_min,
                'viagens_turnos', viagens_turnos, 'viagens_ideal', viagens_ideal, 'areas', areas) from bi_config where id = 1),
    'coleta', (select max(coletado_em) from viagens),
    'primeiro_dia', (select min(data_local) from viagens),
    'hoje', _bi_hoje());
end $$;

create or replace function public.bi_painel_salvar(p_token text, p_id text, p_titulo text default null,
  p_ordem int default null, p_situacao text default null) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true); old bi_paineis;
begin
  select * into old from bi_paineis where id = p_id;
  if old.id is null then raise exception 'Painel não encontrado.'; end if;
  if p_situacao is not null and p_situacao not in ('todos', 'admin', 'excluido') then raise exception 'Situação inválida.'; end if;
  update bi_paineis set titulo = coalesce(nullif(trim(p_titulo), ''), titulo), ordem = coalesce(p_ordem, ordem),
         situacao = coalesce(p_situacao, situacao), atualizado_em = now(), atualizado_por = q->>'nome'
   where id = p_id;
  perform public._central_log((q->>'acesso_id')::bigint, q->>'nome', 'editou', 'bi',
    'Painel ' || old.titulo || ': ' || coalesce(old.situacao, '') || ' → ' || coalesce(p_situacao, old.situacao), 'bi_paineis', p_id,
    jsonb_build_object('situacao', jsonb_build_array(old.situacao, coalesce(p_situacao, old.situacao)),
                       'titulo', jsonb_build_array(old.titulo, coalesce(nullif(trim(p_titulo), ''), old.titulo))));
  return 'ok';
end $$;

create or replace function public.bi_config_salvar(p_token text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true); old bi_config;
begin
  select * into old from bi_config where id = 1;
  update bi_config set
    lugares      = greatest(1, coalesce((p_dados->>'lugares')::int, lugares)),
    valor_pessoa = greatest(0, coalesce((p_dados->>'valor_pessoa')::numeric, valor_pessoa)),
    gap_min      = greatest(1, coalesce((p_dados->>'gap_min')::int, gap_min)),
    viagens_turnos = coalesce((select array_agg(upper(trim(x))) from jsonb_array_elements_text(p_dados->'viagens_turnos') x where trim(x) <> ''), viagens_turnos),
    viagens_ideal  = coalesce(p_dados->'viagens_ideal', viagens_ideal),
    areas          = coalesce(case when jsonb_typeof(p_dados->'areas') = 'array' then p_dados->'areas' end, areas),
    atualizado_em = now(), atualizado_por = q->>'nome'
  where id = 1;
  perform public._central_log((q->>'acesso_id')::bigint, q->>'nome', 'editou', 'bi', 'Ajustes do BI', 'bi_config', '1',
    jsonb_build_object('antes', to_jsonb(old) - 'atualizado_em', 'depois', p_dados));
  return 'ok';
end $$;

-- ---------------------------------------------------------------- cercas
create or replace function public.bi_cercas(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  return (select coalesce(json_agg(json_build_object('id', id, 'nome', nome, 'turno', turno, 'finalidade', finalidade, 'cor', cor, 'pontos', pontos,
            'horarios', horarios, 'ativo', ativo, 'atualizado_por', atualizado_por, 'atualizado_em', atualizado_em) order by nome), '[]'::json)
          from bi_cercas);
end $$;

-- linhas e turnos (tipolinha) que apareceram nas viagens dos últimos 60 dias, para escolher na cerca
create or replace function public.bi_opcoes(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  return json_build_object(
    'tipolinhas', (select coalesce(json_agg(t order by t), '[]'::json) from (select distinct upper(trim(tipolinha)) as t
                   from viagens where data_local > _bi_hoje() - 60 and coalesce(trim(tipolinha), '') <> '') x),
    'linhas', (select coalesce(json_agg(l order by l), '[]'::json) from (select distinct trim(linha) as l
                   from viagens where data_local > _bi_hoje() - 60 and coalesce(trim(linha), '') <> '') x));
end $$;

create or replace function public.bi_cerca_salvar(p_token text, p_dados jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true); v_id bigint := nullif(p_dados->>'id', '')::bigint;
        pts jsonb := coalesce(p_dados->'pontos', '[]'::jsonb); arr float8[]; old bi_cercas;
        v_fin text := coalesce(nullif(p_dados->>'finalidade', ''), 'turno');
begin
  if v_fin not in ('turno', 'terminal', 'fim_rota', 'outra') then raise exception 'Finalidade inválida.'; end if;
  if coalesce(trim(p_dados->>'nome'), '') = '' then raise exception 'Dê um nome para a cerca.'; end if;
  if jsonb_typeof(pts) <> 'array' or jsonb_array_length(pts) < 3 then raise exception 'Marque pelo menos 3 pontos no mapa.'; end if;
  select array_agg(x order by o, k) into arr from (
    select (e->>0)::float8 as x, o, 0 as k from jsonb_array_elements(pts) with ordinality as t(e, o)
    union all
    select (e->>1)::float8, o, 1 from jsonb_array_elements(pts) with ordinality as t(e, o)) s;
  if v_id is null then
    insert into bi_cercas (nome, turno, finalidade, cor, pontos, poly, horarios, ativo, atualizado_por)
    values (trim(p_dados->>'nome'), nullif(trim(p_dados->>'turno'), ''), v_fin, coalesce(nullif(p_dados->>'cor', ''), '#2563eb'), pts, arr,
            coalesce(p_dados->'horarios', '[]'::jsonb), coalesce((p_dados->>'ativo')::boolean, true), q->>'nome')
    returning id into v_id;
  else
    select * into old from bi_cercas where id = v_id;
    if old.id is null then raise exception 'Cerca não encontrada.'; end if;
    update bi_cercas set nome = trim(p_dados->>'nome'), turno = nullif(trim(p_dados->>'turno'), ''), finalidade = v_fin,
           cor = coalesce(nullif(p_dados->>'cor', ''), cor), pontos = pts, poly = arr,
           horarios = coalesce(p_dados->'horarios', '[]'::jsonb), ativo = coalesce((p_dados->>'ativo')::boolean, ativo),
           atualizado_em = now(), atualizado_por = q->>'nome'
     where id = v_id;
    if old.pontos is distinct from pts then delete from bi_cerca_dias where cerca_id = v_id; delete from bi_cerca_eventos where cerca_id = v_id; end if;
  end if;
  update bi_cercas set
    lat_min = (select min(p[i]) from (select poly as p from bi_cercas where id = v_id) z, generate_series(1, array_length(z.p, 1), 2) i),
    lat_max = (select max(p[i]) from (select poly as p from bi_cercas where id = v_id) z, generate_series(1, array_length(z.p, 1), 2) i),
    lon_min = (select min(p[i]) from (select poly as p from bi_cercas where id = v_id) z, generate_series(2, array_length(z.p, 1), 2) i),
    lon_max = (select max(p[i]) from (select poly as p from bi_cercas where id = v_id) z, generate_series(2, array_length(z.p, 1), 2) i)
  where id = v_id;
  perform public._central_log((q->>'acesso_id')::bigint, q->>'nome', 'editou', 'bi',
    case when old.id is null then 'Criou a cerca ' else 'Alterou a cerca ' end || trim(p_dados->>'nome'), 'bi_cercas', v_id::text,
    jsonb_build_object('antes', case when old.id is null then null else jsonb_build_object('nome', old.nome, 'horarios', old.horarios, 'ativo', old.ativo) end,
                       'depois', jsonb_build_object('nome', p_dados->>'nome', 'horarios', p_dados->'horarios', 'ativo', p_dados->'ativo')));
  return v_id;
end $$;

create or replace function public.bi_cerca_remover(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true); n text;
begin
  delete from bi_cercas where id = p_id returning nome into n;
  if n is null then raise exception 'Cerca não encontrada.'; end if;
  perform public._central_log((q->>'acesso_id')::bigint, q->>'nome', 'editou', 'bi', 'Removeu a cerca ' || n, 'bi_cercas', p_id::text);
  return 'ok';
end $$;

-- ---------------------------------------------------------------- entrada / saída pelas cercas
-- Calcula as entradas e saídas de UMA cerca num dia de Belém, a partir das posições do Monitor.
-- entrada = 1ª posição dentro depois de uma posição fora; saída = 1ª posição fora depois de dentro.
create or replace function public._bi_processar(p_cerca bigint, p_dia date) returns int
language plpgsql security definer set search_path = public as $$
declare c bi_cercas; n int; ini timestamptz := (p_dia::timestamp at time zone 'America/Belem');
begin
  select * into c from bi_cercas where id = p_cerca;
  if c.id is null then return 0; end if;
  delete from bi_cerca_eventos where cerca_id = p_cerca and dia = p_dia;
  with s as (
    select device_id, public.normaliza_tag(device_name) as frota, ts,
           (lat between c.lat_min and c.lat_max and lon between c.lon_min and c.lon_max
            and public._bi_dentro(lat, lon, c.poly)) as dentro
    from samples
    where ts >= ini - interval '1 hour' and ts < ini + interval '1 day'
      and lat is not null and lon is not null and not (lat = 0 and lon = 0)
      and public.normaliza_tag(device_name) is not null
  ), t as (
    select device_id, frota, ts, dentro, lag(dentro) over w as antes, lag(ts) over w as ts_antes
    from s window w as (partition by device_id order by ts)
  )
  insert into bi_cerca_eventos (cerca_id, dia, frota, device_id, tipo, ts, gap_min)
  select p_cerca, p_dia, frota, device_id, case when dentro then 'entrada' else 'saida' end, ts,
         round((extract(epoch from ts - ts_antes) / 60.0)::numeric, 1)
  from t where antes is not null and dentro <> antes and ts >= ini
  on conflict do nothing;
  get diagnostics n = row_count;
  insert into bi_cerca_dias (cerca_id, dia, processado_em, frotas)
  values (p_cerca, p_dia, now(), coalesce((select array_agg(distinct public.normaliza_tag(device_name)) from samples
            where ts >= ini and ts < ini + interval '1 day' and lat is not null and public.normaliza_tag(device_name) is not null), '{}'))
  on conflict (cerca_id, dia) do update set processado_em = now(), frotas = excluded.frotas;
  return n;
end $$;
revoke execute on function public._bi_processar(bigint, date) from public, anon, authenticated;

-- A página chama em laços: processa até p_max dias pendentes por chamada (cabe no tempo limite do Supabase)
-- e devolve quantos ainda faltam. Dia pendente = nunca processado ou processado antes de o dia acabar.
create or replace function public.bi_processar(p_token text, p_de date, p_ate date, p_max int default 4) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); r record; feitos int := 0; falta int;
begin
  if p_ate - p_de > 62 then raise exception 'Escolha um período de até 2 meses.'; end if;
  for r in
    select c.id, d::date as dia from bi_cercas c cross join generate_series(p_de, least(p_ate, _bi_hoje()), interval '1 day') d
    left join bi_cerca_dias k on k.cerca_id = c.id and k.dia = d::date
    where c.ativo and (k.dia is null or k.processado_em < ((d::date + 1)::timestamp at time zone 'America/Belem') + interval '10 minutes'
                       and k.processado_em < now() - interval '5 minutes')
    order by d::date, c.id
  loop
    exit when feitos >= greatest(1, least(p_max, 10));
    perform public._bi_processar(r.id, r.dia);
    feitos := feitos + 1;
  end loop;
  select count(*) into falta from bi_cercas c cross join generate_series(p_de, least(p_ate, _bi_hoje()), interval '1 day') d
    left join bi_cerca_dias k on k.cerca_id = c.id and k.dia = d::date
    where c.ativo and (k.dia is null or k.processado_em < ((d::date + 1)::timestamp at time zone 'America/Belem') + interval '10 minutes'
                       and k.processado_em < now() - interval '5 minutes');
  return json_build_object('feitos', feitos, 'falta', falta);
end $$;

-- Uma linha por viagem que cai numa regra de horário de alguma cerca.
-- IDA  → chegada: 1ª entrada na cerca entre 15 min antes da abertura e 30 min depois do fechamento.
-- VOLTA → saída: última saída da cerca entre 60 min antes e 90 min depois da abertura.
create or replace function public._bi_horarios(p_de date, p_ate date)
returns table (data date, cerca text, regra text, cor text, linha text, tipolinha text, tipo text, frota text, motorista text,
               ocupacao int, prevista text, tol_antes int, tol_depois int, monitor text, monitor_gap numeric, tfleet text,
               hora_real text, origem text, dif int, status text, tem_monitor boolean)
language sql stable security definer set search_path = public as $$
with v as (select * from _bi_viagens(p_de, p_ate) where linha is not null and tipo is not null),
reg as (
  select c.id as cid, c.nome, c.cor, r.o, r.h
  from bi_cercas c, jsonb_array_elements(c.horarios) with ordinality as r(h, o)
  where c.ativo and c.finalidade = 'turno'
),
alvo as (
  select v.*, reg.cid, reg.nome as cnome, reg.cor as ccor, coalesce(nullif(reg.h->>'rotulo', ''), reg.nome) as rnome,
         upper(trim(v.tipo)) as sent,
         case when upper(trim(v.tipo)) = 'IDA' then reg.h->>'chegada' else reg.h->>'saida' end as prev,
         case when upper(trim(v.tipo)) = 'IDA' then coalesce((reg.h->>'cheg_antes')::int, 10) else coalesce((reg.h->>'sai_antes')::int, 10) end as ta,
         case when upper(trim(v.tipo)) = 'IDA' then coalesce((reg.h->>'cheg_depois')::int, 10) else coalesce((reg.h->>'sai_depois')::int, 10) end as td
  from v join reg on
        (jsonb_array_length(coalesce(reg.h->'tipolinhas', '[]')) = 0
          or upper(trim(coalesce(v.tipolinha, ''))) in (select upper(trim(x)) from jsonb_array_elements_text(reg.h->'tipolinhas') x))
    and (coalesce(trim(reg.h->>'linha_contem'), '') = '' or upper(v.linha) like '%' || upper(trim(reg.h->>'linha_contem')) || '%')
    and (jsonb_array_length(coalesce(reg.h->'dias', '[]')) = 0
          or extract(isodow from v.data_local)::text in (select jsonb_array_elements_text(reg.h->'dias')))
    and (jsonb_array_length(coalesce(reg.h->'tipolinhas', '[]')) > 0 or coalesce(trim(reg.h->>'linha_contem'), '') <> '')
  where upper(trim(v.tipo)) in ('IDA', 'VOLTA')
    and (case when upper(trim(v.tipo)) = 'IDA' then reg.h->>'chegada' else reg.h->>'saida' end) ~ '^\d{1,2}:\d{2}'
),
com as (
  select a.*,
    (select public.normaliza_tag(a.frota) = any (k.frotas) from bi_cerca_dias k where k.cerca_id = a.cid and k.dia = a.data_local) as tem_mon
  from alvo a
),
ev as (
  select c.*,
    (select e.ts from bi_cerca_eventos e
      where e.cerca_id = c.cid and e.frota = public.normaliza_tag(c.frota)
        and ((c.sent = 'IDA' and e.tipo = 'entrada' and e.ts between c.saida_ts - interval '15 minutes' and coalesce(c.chegada_ts, c.saida_ts + interval '4 hours') + interval '30 minutes')
          or (c.sent = 'VOLTA' and e.tipo = 'saida' and e.ts between c.saida_ts - interval '60 minutes' and c.saida_ts + interval '90 minutes'))
      order by case when c.sent = 'IDA' then extract(epoch from e.ts) else -extract(epoch from e.ts) end limit 1) as ev_ts,
    (select e.gap_min from bi_cerca_eventos e
      where e.cerca_id = c.cid and e.frota = public.normaliza_tag(c.frota)
        and ((c.sent = 'IDA' and e.tipo = 'entrada' and e.ts between c.saida_ts - interval '15 minutes' and coalesce(c.chegada_ts, c.saida_ts + interval '4 hours') + interval '30 minutes')
          or (c.sent = 'VOLTA' and e.tipo = 'saida' and e.ts between c.saida_ts - interval '60 minutes' and c.saida_ts + interval '90 minutes'))
      order by case when c.sent = 'IDA' then extract(epoch from e.ts) else -extract(epoch from e.ts) end limit 1) as ev_gap,
    case when c.sent = 'IDA' then nullif(left(trim(c.bruto->>'hrsla'), 5), '')
         else to_char(c.hora_saida, 'HH24:MI') end as tf
  from com c
),
fim as (
  select e.*, to_char(e.ev_ts at time zone 'America/Belem', 'HH24:MI') as mon,
         coalesce(to_char(e.ev_ts at time zone 'America/Belem', 'HH24:MI'), case when e.tf ~ '^\d{1,2}:\d{2}' and e.tf not in ('00:00') then e.tf end) as rl
  from ev e
)
select f.data_local, f.cnome, f.rnome, f.ccor, f.linha, upper(trim(f.tipolinha)), f.sent, f.frota, f.motorista, f.ocupacao,
       f.prev, f.ta, f.td, f.mon, f.ev_gap, f.tf, f.rl,
       case when f.mon is not null then 'Monitor' when f.rl is not null then (case when f.sent = 'IDA' then 'TFleet (ponto)' else 'TFleet (abertura)' end) end,
       d.dif,
       case when f.rl is null then (case when coalesce(f.tem_mon, false) then 'sem passagem na cerca' else 'sem dado' end)
            when d.dif < -f.ta then 'adiantado' when d.dif > f.td then 'atrasado' else 'no horário' end,
       coalesce(f.tem_mon, false)
from fim f
left join lateral (select ((_bi_min(f.rl) - _bi_min(f.prev) + 720 + 1440) % 1440) - 720 as dif) d on f.rl is not null
order by f.data_local desc, f.cnome, f.linha, f.sent;
$$;
revoke execute on function public._bi_horarios(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- dados de cada painel
-- p_filtros: {"linha": "...", "tipolinha": "...", "sentido": "IDA|VOLTA"}
create or replace function public.bi_dados(p_token text, p_painel text, p_de date, p_ate date, p_filtros jsonb default '{}'::jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); ed boolean := (q->>'edita')::boolean; sit text;
        fl text := nullif(trim(p_filtros->>'linha'), ''); ft text := nullif(upper(trim(p_filtros->>'tipolinha')), '');
        fs text := nullif(upper(trim(p_filtros->>'sentido')), ''); cfg bi_config; res json;
begin
  if p_de is null or p_ate is null or p_ate < p_de then raise exception 'Período inválido.'; end if;
  if p_ate - p_de > 92 then raise exception 'Escolha um período de até 3 meses.'; end if;
  select situacao into sit from bi_paineis where id = p_painel;
  if sit is null or sit = 'excluido' or (sit = 'admin' and not ed) then raise exception 'Painel indisponível.'; end if;
  select * into cfg from bi_config where id = 1;

  if p_painel in ('ocupacao', 'fora_rota', 'custo', 'nao_cad') then
    create temp table if not exists _bi_e on commit drop as select * from embarques limit 0;
    truncate _bi_e;
    insert into _bi_e select * from embarques e
     where e.data_local between p_de and p_ate
       and (fl is null or e.linha = fl) and (ft is null or upper(trim(e.tipolinha)) = ft) and (fs is null or upper(trim(e.sentido)) = fs);
  end if;

  if p_painel = 'ocupacao' then
    with vg as (select * from _bi_viagens(p_de, p_ate) v where (fl is null or v.linha = fl)
                  and (ft is null or upper(trim(v.tipolinha)) = ft) and (fs is null or upper(trim(v.tipo)) = fs))
    select json_build_object(
      'kpi', json_build_object(
         'embarques', (select count(*) from _bi_e),
         'pessoas', (select count(distinct coalesce(matricula, nome)) from _bi_e),
         'viagens', (select count(*) from vg),
         'media_ocup', (select round(avg(ocupacao)::numeric, 1) from vg where ocupacao > 0),
         'pct', (select round(100 * avg(ocupacao)::numeric / cfg.lugares, 1) from vg where ocupacao > 0),
         'lugares', cfg.lugares),
      'por_linha', (select coalesce(json_agg(x order by x.embarques desc), '[]'::json) from (
          select l.linha, l.embarques, l.pessoas, coalesce(w.viagens, 0) as viagens, w.media_ocup,
                 round(100 * w.media_ocup / cfg.lugares, 1) as pct
          from (select linha, count(*) as embarques, count(distinct coalesce(matricula, nome)) as pessoas from _bi_e group by linha) l
          left join (select linha, count(*) as viagens, round(avg(nullif(ocupacao, 0))::numeric, 1) as media_ocup from vg group by linha) w
            on w.linha = l.linha) x),
      'por_dia', (select coalesce(json_agg(x order by x.dia), '[]'::json) from (
          select data_local as dia, count(*) as embarques, count(distinct coalesce(matricula, nome)) as pessoas from _bi_e group by 1) x),
      'por_status', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(upper(trim(tipopassageiro)), ''), 'SEM STATUS') as status, count(*) as n from _bi_e group by 1) x),
      'por_turno', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(upper(trim(tipolinha)), ''), '—') as turno, coalesce(_bi_empresa(bruto->>'empresa'), '—') as empresa, count(*) as n
          from _bi_e group by 1, 2) x),
      'status_linha', (select coalesce(json_agg(x), '[]'::json) from (
          select linha, coalesce(nullif(upper(trim(tipopassageiro)), ''), 'SEM STATUS') as status, count(*) as n from _bi_e group by 1, 2) x)
    ) into res;

  elsif p_painel = 'fora_rota' then
    with b as (
      select e.*, regexp_replace(coalesce(e.linhapassageiro, ''), '\s*-\s*PASSAGEIRO\s*$', '', 'i') as cad from _bi_e e),
    f as (select * from b where upper(coalesce(tipopassageiro, '')) <> 'REGULAR' or (cad <> '' and upper(trim(cad)) <> upper(trim(linha))))
    select json_build_object(
      'kpi', json_build_object('embarques', (select count(*) from b), 'fora', (select count(*) from f),
             'pessoas', (select count(distinct coalesce(matricula, nome)) from f)),
      'por_status', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(upper(trim(tipopassageiro)), ''), 'SEM STATUS') as status, count(*) as n from b group by 1) x),
      'por_gg', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(trim(gg), ''), 'SEM GG') as gg, coalesce(nullif(trim(ga), ''), '—') as ga, count(*) as n from f group by 1, 2) x),
      'lista', (select coalesce(json_agg(x order by x.vezes desc, x.nome), '[]'::json) from (
          select max(nome) as nome, max(matricula) as matricula, max(_bi_empresa(bruto->>'empresa')) as empresa,
                 max(upper(tipopassageiro)) as status, max(nullif(cad, '')) as linha_cadastro,
                 string_agg(distinct linha, ' · ') as linhas_usadas, count(*) as vezes, max(data_local) as ultimo
          from f group by coalesce(matricula, nome) limit 3000) x),
      'pontos', (select coalesce(json_agg(json_build_array(round(lat::numeric, 5), round(lon::numeric, 5), upper(coalesce(tipopassageiro, '')))), '[]'::json)
                 from (select lat, lon, tipopassageiro from f where _bi_na_area(lat, lon, cfg.areas) limit 4000) p),
      'pontos_fora_area', (select count(*) from f where lat is not null and not _bi_na_area(lat, lon, cfg.areas))
    ) into res;

  elsif p_painel = 'custo' then
    select json_build_object(
      'valor_pessoa', cfg.valor_pessoa,
      'kpi', json_build_object('embarques', (select count(*) from _bi_e), 'total', (select count(*) * cfg.valor_pessoa from _bi_e)),
      'por_gg', (select coalesce(json_agg(x order by x.valor desc), '[]'::json) from (
          select coalesce(nullif(trim(gg), ''), 'SEM GG') as gg, count(*) as n, count(*) * cfg.valor_pessoa as valor from _bi_e group by 1) x),
      'por_empresa', (select coalesce(json_agg(x order by x.valor desc), '[]'::json) from (
          select coalesce(_bi_empresa(bruto->>'empresa'), '—') as empresa, count(*) as n, count(*) * cfg.valor_pessoa as valor from _bi_e group by 1) x),
      'por_turno', (select coalesce(json_agg(x order by x.valor desc), '[]'::json) from (
          select coalesce(nullif(upper(trim(tipolinha)), ''), '—') as turno, count(*) as n, count(*) * cfg.valor_pessoa as valor from _bi_e group by 1) x),
      'por_linha', (select coalesce(json_agg(x order by x.valor desc), '[]'::json) from (
          select linha, count(*) as n, count(*) * cfg.valor_pessoa as valor from _bi_e group by 1) x)
    ) into res;

  elsif p_painel = 'nao_cad' then
    with f as (select * from _bi_e where upper(coalesce(tipopassageiro, '')) in ('NAO CADASTRADO', 'NÃO CADASTRADO', 'ITINERANTE'))
    select json_build_object(
      'kpi', json_build_object('embarques', (select count(*) from f),
             'nao_cad', (select count(*) from f where upper(tipopassageiro) like 'N%'),
             'itinerantes', (select count(*) from f where upper(tipopassageiro) = 'ITINERANTE')),
      'por_linha', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (select linha, count(*) as n from f group by 1) x),
      'por_gg', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(trim(gg), ''), 'SEM GG') as gg, coalesce(nullif(trim(ga), ''), '—') as ga,
                 coalesce(nullif(trim(centrocusto), ''), '—') as cc, count(*) as n from f group by 1, 2, 3) x),
      'lista', (select coalesce(json_agg(x order by x.vezes desc), '[]'::json) from (
          select max(upper(tipopassageiro)) as status, max(nome) as nome, max(matricula) as matricula,
                 max(_bi_empresa(bruto->>'empresa')) as empresa, max(linhapassageiro) as linha_cadastro,
                 string_agg(distinct linha, ' · ') as linhas, max(coalesce(bruto->>'codigoid', bruto->>'rfid')) as cracha,
                 count(*) as vezes, max(data_local) as ultimo
          from f group by coalesce(nullif(matricula, ''), nullif(bruto->>'codigoid', ''), nome) limit 3000) x)
    ) into res;

  elsif p_painel = 'viagens' then
    with vg as (select * from _bi_viagens(p_de, p_ate) v where upper(trim(coalesce(v.tipolinha, ''))) = any (cfg.viagens_turnos)
                  and (fl is null or v.linha = fl)
                  and (ft is null or upper(trim(v.tipolinha)) = ft) and (fs is null or upper(trim(v.tipo)) = fs))
    select json_build_object(
      'kpi', json_build_object('viagens', (select count(*) from vg), 'dias', (select count(distinct data_local) from vg),
             'media_dia', (select round(count(*)::numeric / nullif(count(distinct data_local), 0), 1) from vg)),
      'por_dia', (select coalesce(json_agg(x order by x.dia, x.turno), '[]'::json) from (
          select data_local as dia, coalesce(nullif(upper(trim(tipolinha)), ''), '—') as turno, count(*) as n from vg group by 1, 2) x),
      'por_turno', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
          select coalesce(nullif(upper(trim(tipolinha)), ''), '—') as turno, count(*) as n,
                 round(count(*)::numeric / nullif(count(distinct data_local), 0), 1) as media_dia from vg group by 1) x),
      'turnos', cfg.viagens_turnos, 'ideal', cfg.viagens_ideal
    ) into res;

  elsif p_painel = 'horarios' then
    if p_ate - p_de > 62 then raise exception 'Escolha um período de até 2 meses.'; end if;
    select json_build_object(
      'cercas', (select count(*) from bi_cercas where ativo and finalidade = 'turno'),
      'pendentes', (select count(*) from bi_cercas c cross join generate_series(p_de, least(p_ate, _bi_hoje()), interval '1 day') d
                    left join bi_cerca_dias k on k.cerca_id = c.id and k.dia = d::date where c.ativo and k.dia is null),
      'linhas', (select coalesce(json_agg(h), '[]'::json) from _bi_horarios(p_de, p_ate) h
                 where (fl is null or h.linha = fl) and (ft is null or h.tipolinha = ft) and (fs is null or h.tipo = fs))
    ) into res;

  else
    raise exception 'Painel desconhecido.';
  end if;
  return res;
end $$;

-- ---------------------------------------------------------------- detalhe (drill-down) de qualquer indicador
-- p_tipo: 'viagens' ou 'embarques'; p_campo/p_valor: linha, dia, turno, status, empresa, gg, sentido (filtra além dos filtros da tela)
create or replace function public.bi_detalhe(p_token text, p_tipo text, p_de date, p_ate date, p_filtros jsonb default '{}'::jsonb,
  p_campo text default null, p_valor text default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
        fl text := nullif(trim(p_filtros->>'linha'), ''); ft text := nullif(upper(trim(p_filtros->>'tipolinha')), '');
        fs text := nullif(upper(trim(p_filtros->>'sentido')), ''); vv text := nullif(trim(p_valor), ''); cfg bi_config;
begin
  if p_ate - p_de > 92 then raise exception 'Escolha um período de até 3 meses.'; end if;
  select * into cfg from bi_config where id = 1;
  if p_tipo = 'viagens' then
    return (select coalesce(json_agg(x order by x.data desc, x.hora desc), '[]'::json) from (
      select v.data_local as data, to_char(v.hora_saida, 'HH24:MI') as hora, to_char(v.chegada_ts at time zone 'America/Belem', 'HH24:MI') as chegada,
             upper(trim(v.tipolinha)) as turno, v.linha, upper(trim(v.tipo)) as sentido, v.frota as carro, v.motorista, v.ocupacao,
             nullif(left(trim(v.bruto->>'hrsla'), 5), '') as hora_ponto
      from _bi_viagens(p_de, p_ate) v
      where (fl is null or v.linha = fl) and (ft is null or upper(trim(v.tipolinha)) = ft) and (fs is null or upper(trim(v.tipo)) = fs)
        and (coalesce(p_filtros->>'so_turnos_viagens', '') <> 'sim' or upper(trim(coalesce(v.tipolinha, ''))) = any (cfg.viagens_turnos))
        and (vv is null or case p_campo when 'linha' then v.linha = vv when 'dia' then v.data_local = vv::date
               when 'turno' then upper(trim(coalesce(v.tipolinha, ''))) = upper(vv) when 'sentido' then upper(trim(v.tipo)) = upper(vv)
               when 'carro' then v.frota = vv else true end)
      limit 3000) x);
  elsif p_tipo = 'embarques' then
    return (select coalesce(json_agg(x order by x.data desc, x.hora desc), '[]'::json) from (
      select e.data_local as data, to_char(e.hora, 'HH24:MI') as hora, e.nome, e.matricula, _bi_empresa(e.bruto->>'empresa') as empresa,
             upper(e.tipopassageiro) as status, e.linha, e.linhapassageiro as linha_cadastro, upper(e.sentido) as sentido,
             upper(trim(e.tipolinha)) as turno, e.frota as carro, e.gg, e.ga
      from embarques e
      where e.data_local between p_de and p_ate
        and (fl is null or e.linha = fl) and (ft is null or upper(trim(e.tipolinha)) = ft) and (fs is null or upper(trim(e.sentido)) = fs)
        and (vv is null or case p_campo when 'linha' then e.linha = vv when 'dia' then e.data_local = vv::date
               when 'turno' then upper(trim(coalesce(e.tipolinha, ''))) = upper(vv)
               when 'status' then coalesce(nullif(upper(trim(e.tipopassageiro)), ''), 'SEM STATUS') = upper(vv)
               when 'empresa' then coalesce(_bi_empresa(e.bruto->>'empresa'), '—') = vv
               when 'gg' then coalesce(nullif(trim(e.gg), ''), 'SEM GG') = vv else true end)
      limit 3000) x);
  end if;
  raise exception 'Detalhe desconhecido.';
end $$;

-- ---------------------------------------------------------------- permissões das funções públicas
grant execute on function public.bi_entrar(text), public.bi_sessao(text), public.bi_sair(text), public.bi_inicio(text),
  public.bi_painel_salvar(text, text, text, int, text), public.bi_config_salvar(text, jsonb), public.bi_cercas(text),
  public.bi_opcoes(text), public.bi_cerca_salvar(text, jsonb), public.bi_cerca_remover(text, bigint),
  public.bi_processar(text, date, date, int), public.bi_dados(text, text, date, date, jsonb),
  public.bi_detalhe(text, text, date, date, jsonb, text, text)
  to anon, authenticated;

-- se o PostgREST não enxergar as funções novas na hora:
notify pgrst, 'reload schema';
