-- =====================================================================================
-- BI · HORA INFORMADA PELO MOTORISTA (planilha do Forms "CONTROLE DE OCUPAÇÃO E PONTUALIDADE")
-- Rode no Supabase → SQL Editor, DEPOIS do bi.sql e do eventos.sql. Pode rodar de novo sem problema.
--
-- O que faz:
--  1. bi_forms: guarda cada linha da aba REGISTRO_VIAGENS (o robô do Apps Script manda a cada 15 min).
--  2. Casa cada registro com a viagem da TFleet: mesma data/hora (até 4 h), mesmo sentido
--     (ENTRADA = IDA, SAÍDA = VOLTA) e a rota "de-para" (JK B → JK - B - ADM; JADERLÂNDIA VIA BURITI TURNO → JADERLÂNDIA - TURNO).
--     Rota sem de-para: casa pelo nome do motorista e, depois de 3 casamentos iguais, aprende a rota sozinho.
--  3. BI Horários ganha a "Hora motorista" (ao lado de TFleet e Monitor) e o botão "Ver justificativa".
--  4. Evento de pontualidade (painel Eventos) passa a dizer a hora que o motorista informou ou que ele não informou.
-- =====================================================================================

-- ---------------------------------------------------------------- texto sem acento, maiúsculo, só letras/números
create or replace function public._bi_fn(t text) returns text
language sql immutable as $$
  select nullif(trim(regexp_replace(regexp_replace(
    translate(upper(coalesce(t, '')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑº°ª', 'AAAAAEEEEIIIIOOOOOUUUUCNOOA'),
    '[^A-Z0-9&]+', ' ', 'g'), '\s+', ' ', 'g')), '');
$$;

-- mesmo motorista? 1º nome igual e (2º nome começa igual ou 2 nomes em comum). "WAGNA CAVALCANTE" = "WAGNA CAVALGANTE DOS SANT"
create or replace function public._bi_mot_ok(a text, b text) returns boolean
language sql immutable as $$
  with x as (
    select array(select w from unnest(string_to_array(coalesce(_bi_fn(a), ''), ' ')) w where w <> '' and w not in ('DA', 'DE', 'DO', 'DOS', 'DAS', 'E')) as p,
           array(select w from unnest(string_to_array(coalesce(_bi_fn(b), ''), ' ')) w where w <> '' and w not in ('DA', 'DE', 'DO', 'DOS', 'DAS', 'E')) as q)
  select coalesce(cardinality(p) > 0 and cardinality(q) > 0 and p[1] = q[1]
         and (cardinality(p) < 2 or cardinality(q) < 2 or left(p[2], 3) = left(q[2], 3)
              or (select count(*) from unnest(p) w where w = any (q)) >= 2), false)
  from x;
$$;

-- a "Operação" do Forms combina com o turno da linha na TFleet? (só desempate: o Forms às vezes vem com o turno errado)
create or replace function public._bi_op_ok(op text, tl text) returns boolean
language sql immutable as $$
  select case
    when _bi_fn(op) is null then true
    when _bi_fn(op) like '%ADM%' then upper(coalesce(tl, '')) = 'ADM'
    when _bi_fn(op) ~ '(^|\D)1\D*TURNO|TURNO\D*0?1(\D|$)|^1 ' then upper(coalesce(tl, '')) like 'TURNO 01%' or upper(coalesce(tl, '')) like 'TURNO 1%'
    when _bi_fn(op) ~ '(^|\D)2\D*TURNO|TURNO\D*0?2(\D|$)|^2 ' then upper(coalesce(tl, '')) like 'TURNO 02%' or upper(coalesce(tl, '')) like 'TURNO 2%'
    when _bi_fn(op) ~ '(^|\D)3\D*TURNO|TURNO\D*0?3(\D|$)|^3 ' then upper(coalesce(tl, '')) like 'TURNO 03%'
    else true end;
$$;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.bi_forms (
  uid           text primary key,           -- coluna UID da planilha
  n             int,                        -- coluna ID
  data          date not null,              -- data da viagem
  hora          text,                       -- "07:03" = hora que o motorista diz que chegou (ENTRADA) / saiu (SAÍDA)
  motorista     text,
  matricula     text,
  veiculo       text,
  rota          text,
  operacao      text,                       -- ADM / 1º TURNO / 2º TURNO / VAN / EXTRA
  sentido       text,                       -- ENTRADA / SAÍDA
  passageiros   int,
  capacidade    int,
  ocupacao      numeric,
  registrado_em text,                       -- Data/Hora Registro (como veio)
  status        text,
  recebido_em   timestamptz not null default now(),
  -- casamento com a viagem da TFleet
  viagem_id     text,
  v_data        date,
  v_linha       text,
  v_tipolinha   text,
  v_tipo        text,
  v_frota       text,
  v_motorista   text,
  casou_por     text,                       -- rota (de-para) | motorista
  casado_em     timestamptz,
  tentado_em    timestamptz
);
create index if not exists bi_forms_data on public.bi_forms (data);
create index if not exists bi_forms_v on public.bi_forms (v_data, v_linha, v_tipo);
alter table public.bi_forms enable row level security;
revoke all on public.bi_forms from anon, authenticated;

-- de-para: rota do Forms (sem acento) → linha da TFleet
create table if not exists public.bi_forms_rotas (
  rota          text primary key,           -- _bi_fn(rota do Forms)
  exemplo       text,                       -- como aparece na planilha
  linha         text,                       -- linha da TFleet (null + ignorar = não entra no BI)
  origem        text not null default 'sugerida' check (origem in ('manual', 'sugerida', 'aprendida', 'ignorar')),
  votos         int,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.bi_forms_rotas enable row level security;
revoke all on public.bi_forms_rotas from anon, authenticated;

-- sugestões iniciais (conferidas com as viagens de outubro: mesmo motorista, mesmo dia e sentido). O Mizael pode trocar em ⚙ Gerenciar.
insert into public.bi_forms_rotas (rota, exemplo, linha, origem) values
  (_bi_fn('PROMISSÃO - A'), 'PROMISSÃO - A', 'PROMISSÃO A - ADM', 'sugerida'),
  (_bi_fn('PROMISSÃO - B'), 'PROMISSÃO - B', 'PROMISSÃO B - ADM', 'sugerida'),
  (_bi_fn('PROMISSÃO - C'), 'PROMISSÃO - C', 'PROMISSÃO C - ADM', 'sugerida'),
  (_bi_fn('PROMISSÃO D'), 'PROMISSÃO D', 'PROMISSÃO D - ADM', 'sugerida'),
  (_bi_fn('CAMBOATÃ - A'), 'CAMBOATÃ - A', 'CAMBOATÃ A - ADM', 'sugerida'),
  (_bi_fn('CAMBOATÃ - B'), 'CAMBOATÃ - B', 'CAMBOATÃ B - ADM', 'sugerida'),
  (_bi_fn('CAMBOATÃ C'), 'CAMBOATÃ C', 'CAMBOATÃ C - ADM', 'sugerida'),
  (_bi_fn('FLAMBOYANT - A'), 'FLAMBOYANT - A', 'FLAMBOYANT - ADM', 'sugerida'),
  (_bi_fn('FLAMBOYANT - B'), 'FLAMBOYANT - B', 'FLAMBOYANT B - ADM', 'sugerida'),
  (_bi_fn('JARDIM ATLÂNTICO A'), 'JARDIM ATLÂNTICO A', 'JD ATLÂNTICO A - ADM', 'sugerida'),
  (_bi_fn('JARDIM ATLÂNTICO B'), 'JARDIM ATLÂNTICO B', 'JD ATLÂNTICO B  - ADM', 'sugerida'),
  (_bi_fn('OLGA MOREIRA A'), 'OLGA MOREIRA A', 'OLGA - ADM', 'sugerida'),
  (_bi_fn('OLGA B ADM'), 'OLGA B ADM', 'OLGA B - ADM', 'sugerida'),
  (_bi_fn('OLGA C'), 'OLGA C', 'OLGA C - ADM', 'sugerida'),
  (_bi_fn('JK A'), 'JK A', 'JK - A - ADM', 'sugerida'),
  (_bi_fn('JK B'), 'JK B', 'JK - B - ADM', 'sugerida'),
  (_bi_fn('NAGIBÃO'), 'NAGIBÃO', 'NAGIBÃO ADM', 'sugerida'),
  (_bi_fn('JADERLANDIA'), 'JADERLANDIA', 'JADERLÂNDIA - ADM', 'sugerida'),
  (_bi_fn('JARDIM BELA VISTA'), 'JARDIM BELA VISTA', 'JD BELA VISTA - ADM', 'sugerida'),
  (_bi_fn('URAIM'), 'URAIM', 'URAIM - ADM', 'sugerida'),
  (_bi_fn('SODEXO INDUSTRIAL'), 'SODEXO INDUSTRIAL', 'SODEXO INDUSTRIAL', 'sugerida'),
  (_bi_fn('CT2'), 'CT2', 'CT2', 'sugerida'),
  (_bi_fn('CT3'), 'CT3', 'CT3', 'sugerida'),
  (_bi_fn('CT4 (RBS)'), 'CT4 (RBS)', 'CT4', 'sugerida'),
  (_bi_fn('D3M CT1'), 'D3M CT1', 'CT1', 'sugerida'),
  (_bi_fn('H&F I'), 'H&F I', 'CT5 - H&F 01', 'sugerida'),
  (_bi_fn('H&F II'), 'H&F II', 'CT6 - H&F 02', 'sugerida'),
  (_bi_fn('CT8 ÔMEGA I'), 'CT8 ÔMEGA I', 'CT8 - ÔMEGA', 'sugerida'),
  (_bi_fn('SUPERUS I'), 'SUPERUS I', 'SUPERUS 01', 'sugerida'),
  (_bi_fn('SUPERUS II'), 'SUPERUS II', 'SUPERUS 02', 'sugerida'),
  (_bi_fn('PROMISSÃO TURNO'), 'PROMISSÃO TURNO', 'PROMISSÃO A - TURNO', 'sugerida'),
  (_bi_fn('JADERLÂNDIA VIA BURITI TURNO'), 'JADERLÂNDIA VIA BURITI TURNO', 'JADERLÂNDIA - TURNO', 'sugerida'),
  (_bi_fn('JARDIM ATLÂNTICO VIA NAGIBÃO TURNO'), 'JARDIM ATLÂNTICO VIA NAGIBÃO TURNO', 'JD ATLÂNTICO  A - TURNO', 'sugerida'),
  (_bi_fn('JK TURNO'), 'JK TURNO', 'JK - TURNO', 'sugerida'),
  (_bi_fn('CAMBOATÃ TURNO'), 'CAMBOATÃ TURNO', 'CAMBOATÃ - TURNO', 'sugerida'),
  (_bi_fn('JARDIM ATLÂNTICO GEMIN'), 'JARDIM ATLÂNTICO GEMIN', 'JD ATLÂNTICO MINA - TURNO', 'sugerida'),
  (_bi_fn('CAMBOATÃ GEMIN'), 'CAMBOATÃ GEMIN', 'CAMBOATÃ - MINA - TURNO', 'sugerida'),
  (_bi_fn('JK GEMIN'), 'JK GEMIN', 'JK MINA - TURNO', 'sugerida'),
  (_bi_fn('PROMISSÃO GEMIN'), 'PROMISSÃO GEMIN', 'PROMISSÃO MINA - TURNO', 'sugerida'),
  (_bi_fn('VAN SUPERVISORES 24 HORAS'), 'VAN SUPERVISORES 24 HORAS', null, 'ignorar'),
  (_bi_fn('EXTRA BRITAGEM'), 'EXTRA BRITAGEM', null, 'ignorar'),
  (_bi_fn('EXTRA USINA'), 'EXTRA USINA', null, 'ignorar'),
  (_bi_fn('EXTRA IN-HAUS'), 'EXTRA IN-HAUS', null, 'ignorar'),
  (_bi_fn('JANTAR + APOIO RP1'), 'JANTAR + APOIO RP1', null, 'ignorar'),
  (_bi_fn('TREINAMENTO TURMA A'), 'TREINAMENTO TURMA A', null, 'ignorar'),
  (_bi_fn('PARAGOMINAS X BELÉM'), 'PARAGOMINAS X BELÉM', null, 'ignorar'),
  (_bi_fn('BELÉM X PARAGOMINAS'), 'BELÉM X PARAGOMINAS', null, 'ignorar')
on conflict (rota) do nothing;

-- tolerância para dizer que a hora do motorista "bate" com a medida (min)
alter table public.bi_config add column if not exists forms_tol int not null default 5;

-- ---------------------------------------------------------------- casar registros do Forms com as viagens
-- p_uids = registros a casar. Devolve quantos casaram.
create or replace function public._bi_forms_casar(p_uids text[]) returns int
language plpgsql security definer set search_path = public as $$
declare d0 date; d1 date; qt int := 0;
begin
  select min(data), max(data) into d0, d1 from bi_forms where uid = any (p_uids);
  if d0 is null then return 0; end if;
  update bi_forms set viagem_id = null, v_data = null, v_linha = null, v_tipolinha = null, v_tipo = null, v_frota = null,
         v_motorista = null, casou_por = null, casado_em = null where uid = any (p_uids) and casado_em is not null;

  -- aprende rotas novas: rota sem de-para que casou pelo motorista 3+ vezes com a mesma linha (70% ou mais)
  insert into bi_forms_rotas (rota, exemplo, linha, origem, votos)
  select r, ex, l, 'aprendida', v from (
    select _bi_fn(f.rota) as r, max(f.rota) as ex, f.v_linha as l, count(*) as v,
           sum(count(*)) over (partition by _bi_fn(f.rota)) as tot,
           row_number() over (partition by _bi_fn(f.rota) order by count(*) desc) as rk
    from bi_forms f
    where f.casou_por = 'motorista' and f.v_linha is not null
      and not exists (select 1 from bi_forms_rotas x where x.rota = _bi_fn(f.rota) and x.origem in ('manual', 'sugerida', 'ignorar'))
    group by _bi_fn(f.rota), f.v_linha) z
  where rk = 1 and v >= 3 and v >= 0.7 * tot
  on conflict (rota) do update set linha = excluded.linha, votos = excluded.votos, atualizado_em = now()
    where bi_forms_rotas.origem = 'aprendida';

  with f as (
    select b.uid, b.data, b.motorista, b.veiculo, b.operacao, r.linha as dl, r.origem as dorig,
           ((b.data + b.hora::time) at time zone 'America/Belem') as fts,
           case when _bi_fn(b.sentido) like 'ENTR%' then 'IDA' when _bi_fn(b.sentido) like 'SA%' then 'VOLTA' end as ft,
           _bi_fn(r.linha) as ndl, split_part(_bi_fn(b.motorista), ' ', 1) as m1
    from bi_forms b left join bi_forms_rotas r on r.rota = _bi_fn(b.rota)
    where b.uid = any (p_uids) and b.hora ~ '^\d{1,2}:\d{2}' and coalesce(r.origem, '') <> 'ignorar'
      and coalesce(lower(b.status), '') !~ 'cancel|exclu'),
  v as (
    select x.id, x.linha, upper(trim(x.tipolinha)) as tl, upper(trim(x.tipo)) as tp, x.frota, x.motorista, x.data_local,
           _bi_fn(x.linha) as nl, split_part(_bi_fn(x.motorista), ' ', 1) as m1,
           -- hora de referência da viagem: IDA = chegada no ponto (hrsla) ou fim da viagem; VOLTA = abertura
           case when upper(trim(x.tipo)) = 'IDA' then coalesce(
                  case when left(trim(x.bruto->>'hrsla'), 5) ~ '^\d{2}:\d{2}$' and left(trim(x.bruto->>'hrsla'), 5) <> '00:00'
                       then (x.data_local + left(trim(x.bruto->>'hrsla'), 5)::time) at time zone 'America/Belem' end, x.chegada_ts, x.saida_ts)
                else x.saida_ts end as ref
    from _bi_viagens(d0 - 1, d1 + 1) x where upper(trim(x.tipo)) in ('IDA', 'VOLTA')),
  cand as (
    -- com de-para: pela linha
    select f.uid, v.*, 'rota' as por, _bi_mot_ok(f.motorista, v.motorista) as mok,
           public._bi_op_ok(f.operacao, v.tl) as opk, (public.normaliza_tag(v.frota) = public.normaliza_tag(f.veiculo)) as fok,
           abs(extract(epoch from v.ref - f.fts)) as seg
    from f join v on v.nl = f.ndl and v.tp = f.ft
    where f.ndl is not null and abs(extract(epoch from v.ref - f.fts)) <= 4 * 3600
    union all
    -- sem de-para: pelo motorista
    select f.uid, v.*, 'motorista', true, public._bi_op_ok(f.operacao, v.tl), (public.normaliza_tag(v.frota) = public.normaliza_tag(f.veiculo)),
           abs(extract(epoch from v.ref - f.fts))
    from f join v on v.m1 = f.m1 and v.tp = f.ft
    where f.ndl is null and abs(extract(epoch from v.ref - f.fts)) <= 4 * 3600 and _bi_mot_ok(f.motorista, v.motorista)),
  esc as (
    select distinct on (uid) * from cand
    order by uid, opk desc, mok desc, fok desc, seg)
  update bi_forms b set viagem_id = e.id, v_data = e.data_local, v_linha = e.linha, v_tipolinha = e.tl, v_tipo = e.tp,
         v_frota = e.frota, v_motorista = e.motorista, casou_por = e.por, casado_em = now()
  from esc e where b.uid = e.uid;
  get diagnostics qt = row_count;

  -- o que não achou viagem fica sem casamento (tenta de novo depois: a viagem pode chegar na próxima coleta)
  update bi_forms set tentado_em = now() where uid = any (p_uids);
  return qt;
end $$;
revoke execute on function public._bi_forms_casar(text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------- robô (Apps Script) manda as linhas da planilha
-- p_linhas = [{uid, id, data "01/10/2026", hora "07:03:00", motorista, matricula, veiculo, rota, operacao, sentido,
--              passageiros, capacidade, ocupacao "31,1", registro, status}]
create or replace function public.bi_forms_receber(p_chave text, p_linhas jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare u text[]; qt int; c int; pend text[];
begin
  if not exists (select 1 from sol_config where id = 1 and chave_robo = p_chave) then raise exception 'Chave do robô inválida.'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'p_linhas deve ser uma lista.'; end if;
  with x as (
    select nullif(trim(j->>'uid'), '') as uid,
           case when trim(j->>'id') ~ '^\d+$' then trim(j->>'id')::int end as n,
           case when trim(j->>'data') ~ '^\d{1,2}/\d{1,2}/\d{4}' then to_date(left(trim(j->>'data'), 10), 'DD/MM/YYYY')
                when trim(j->>'data') ~ '^\d{4}-\d{2}-\d{2}' then left(trim(j->>'data'), 10)::date end as data,
           case when trim(j->>'hora') ~ '^\d{1,2}:\d{2}' then lpad(split_part(trim(j->>'hora'), ':', 1), 2, '0') || ':' || left(split_part(trim(j->>'hora'), ':', 2), 2) end as hora,
           nullif(trim(j->>'motorista'), '') as motorista, nullif(trim(j->>'matricula'), '') as matricula, nullif(trim(j->>'veiculo'), '') as veiculo,
           nullif(trim(j->>'rota'), '') as rota, nullif(trim(j->>'operacao'), '') as operacao, nullif(upper(trim(j->>'sentido')), '') as sentido,
           case when trim(j->>'passageiros') ~ '^\d+$' then trim(j->>'passageiros')::int end as passageiros,
           case when trim(j->>'capacidade') ~ '^\d+$' then trim(j->>'capacidade')::int end as capacidade,
           case when replace(trim(j->>'ocupacao'), ',', '.') ~ '^\d+(\.\d+)?$' then replace(trim(j->>'ocupacao'), ',', '.')::numeric end as ocupacao,
           nullif(trim(j->>'registro'), '') as registrado_em, nullif(trim(j->>'status'), '') as status
    from jsonb_array_elements(p_linhas) j),
  ins as (
    insert into bi_forms as b (uid, n, data, hora, motorista, matricula, veiculo, rota, operacao, sentido, passageiros, capacidade, ocupacao, registrado_em, status)
    select distinct on (uid) uid, n, data, hora, motorista, matricula, veiculo, rota, operacao, sentido, passageiros, capacidade, ocupacao, registrado_em, status
    from x where uid is not null and data is not null order by uid
    on conflict (uid) do update set n = excluded.n, data = excluded.data, hora = excluded.hora, motorista = excluded.motorista,
      matricula = excluded.matricula, veiculo = excluded.veiculo, rota = excluded.rota, operacao = excluded.operacao, sentido = excluded.sentido,
      passageiros = excluded.passageiros, capacidade = excluded.capacidade, ocupacao = excluded.ocupacao,
      registrado_em = excluded.registrado_em, status = excluded.status, recebido_em = now(),
      -- mudou data/hora/rota/sentido/motorista: casa de novo
      casado_em = case when (b.data, b.hora, b.rota, b.sentido, b.motorista) is distinct from
                            (excluded.data, excluded.hora, excluded.rota, excluded.sentido, excluded.motorista) then null else b.casado_em end
    returning b.uid, b.casado_em)
  select array_agg(uid) filter (where casado_em is null), count(*) into u, qt from ins;
  -- também tenta de novo os que ficaram sem viagem nos últimos 10 dias (a coleta da TFleet pode ter atrasado)
  select array_agg(uid) into pend from (select uid from bi_forms where casado_em is null and data >= _bi_hoje() - 10
                                        and (tentado_em is null or tentado_em < now() - interval '30 minutes') and not (uid = any (coalesce(u, '{}'))) limit 300) z;
  c := _bi_forms_casar(coalesce(u, '{}') || coalesce(pend, '{}'));
  return json_build_object('recebidas', coalesce(qt, 0), 'casadas', c);
end $$;
grant execute on function public.bi_forms_receber(text, jsonb) to anon;

-- ---------------------------------------------------------------- BI: hora do motorista + justificativa por viagem do Horários
-- chave da viagem no Horários = data|linha|sentido|carro
create or replace function public.bi_horarios_motorista(p_token text, p_de date, p_ate date) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); tem_ev boolean := to_regclass('public.ev_eventos') is not null; ev json := '[]'::json;
begin
  if p_ate - p_de > 92 then raise exception 'Escolha um período de até 3 meses.'; end if;
  if tem_ev then
    execute $q$ select coalesce(json_agg(json_build_object('chave', e.chave, 'id', e.id, 'situacao', e.situacao, 'motivo', e.motivo)), '[]'::json)
                from ev_eventos e where e.tipo = 'pontualidade' and e.data between $1 and $2 $q$ into ev using p_de, p_ate;
  end if;
  return json_build_object(
    'tol', (select forms_tol from bi_config where id = 1),
    'instalado', true,
    'forms', (select coalesce(json_agg(json_build_object(
                 'k', f.v_data || '|' || f.v_linha || '|' || f.v_tipo || '|' || coalesce(f.v_frota, ''),
                 'hora', f.hora, 'motorista', f.motorista, 'veiculo', f.veiculo, 'rota', f.rota, 'passageiros', f.passageiros,
                 'registro', f.registrado_em) order by f.v_data, f.hora), '[]'::json)
              from bi_forms f where f.v_data between p_de and p_ate and f.viagem_id is not null),
    'ultimo', (select max(recebido_em) from bi_forms),
    'eventos', ev);
end $$;

-- justificativa de uma viagem (evento de pontualidade do painel Eventos)
create or replace function public.bi_justificativa(p_token text, p_chave text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); r json;
begin
  if to_regclass('public.ev_eventos') is null then return null; end if;
  execute $q$ select json_build_object(
      'id', e.id, 'situacao', e.situacao, 'titulo', e.titulo, 'motivo', e.motivo, 'justificativa', e.justificativa,
      'respondido_por', e.respondido_por, 'respondido_em', e.respondido_em, 'analise_por', e.analise_por, 'analise_em', e.analise_em,
      'analise_obs', e.analise_obs, 'prazo', e.prazo, 'criado_em', e.criado_em,
      'evid', (select coalesce(json_agg(json_build_object('id', v.id, 'nome', v.nome, 'tamanho', v.tamanho, 'por', v.enviado_por, 'em', v.enviado_em) order by v.id), '[]'::json)
               from ev_evidencias v where v.evento_id = e.id),
      'historico', (select coalesce(json_agg(json_build_object('ts', h.ts, 'quem', h.quem, 'acao', h.acao, 'texto', h.texto) order by h.ts), '[]'::json)
               from ev_historico h where h.evento_id = e.id),
      'envios', (select coalesce(json_agg(json_build_object('nome', v.nome, 'canal', v.canal, 'enviado_em', v.enviado_em, 'aberto_em', v.aberto_em) order by v.id), '[]'::json)
               from ev_envio_itens x join ev_envios v on v.id = x.envio_id where x.evento_id = e.id))
    from ev_eventos e where e.tipo = 'pontualidade' and e.chave = $1 $q$ into r using p_chave;
  return r;
end $$;

-- ---------------------------------------------------------------- Gerenciar: situação do robô e de-para das rotas
create or replace function public.bi_forms_status(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  return json_build_object(
    'total', (select count(*) from bi_forms),
    'casados', (select count(*) from bi_forms where viagem_id is not null),
    'ultimo', (select max(recebido_em) from bi_forms),
    'ultima_data', (select max(data) from bi_forms),
    'rotas', (select coalesce(json_agg(x order by x.sem desc, x.exemplo), '[]'::json) from (
        select coalesce(r.rota, z.rota) as rota, coalesce(r.exemplo, z.exemplo) as exemplo, r.linha, coalesce(r.origem, 'sem de-para') as origem,
               r.atualizado_por, coalesce(z.n, 0) as registros, coalesce(z.casados, 0) as casados, coalesce(z.n, 0) - coalesce(z.casados, 0) as sem,
               z.ultimo
        from bi_forms_rotas r
        full join (select _bi_fn(rota) as rota, max(rota) as exemplo, count(*) as n, count(viagem_id) as casados, max(data) as ultimo
                   from bi_forms where data > _bi_hoje() - 60 group by 1) z on z.rota = r.rota) x));
end $$;

-- p_linha vazio + p_ignorar = rota não entra no BI (van, extra...)
create or replace function public.bi_forms_rota_salvar(p_token text, p_rota text, p_linha text, p_ignorar boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token, true); k text := _bi_fn(p_rota); u text[]; c int;
begin
  if k is null then raise exception 'Rota vazia.'; end if;
  insert into bi_forms_rotas (rota, exemplo, linha, origem, atualizado_por)
  values (k, p_rota, case when p_ignorar then null else nullif(trim(p_linha), '') end,
          case when p_ignorar then 'ignorar' when nullif(trim(p_linha), '') is null then 'sugerida' else 'manual' end, q->>'nome')
  on conflict (rota) do update set linha = excluded.linha, origem = excluded.origem, atualizado_por = excluded.atualizado_por, atualizado_em = now();
  if not p_ignorar and nullif(trim(p_linha), '') is null then delete from bi_forms_rotas where rota = k; end if;
  -- casa de novo os registros dessa rota (últimos 90 dias)
  update bi_forms set viagem_id = null, v_data = null, v_linha = null, v_tipolinha = null, v_tipo = null, v_frota = null,
         v_motorista = null, casou_por = null, casado_em = null where _bi_fn(rota) = k;
  select array_agg(uid) into u from bi_forms where _bi_fn(rota) = k and data > _bi_hoje() - 90;
  c := _bi_forms_casar(coalesce(u, '{}'));
  return json_build_object('registros', coalesce(cardinality(u), 0), 'casados', c);
end $$;

-- ---------------------------------------------------------------- painel Eventos: o aviso de pontualidade diz o que o motorista informou
-- (trigger: não muda o robô de eventos; quando o Forms chega depois do aviso, completa o detalhe do evento)
create or replace function public._bi_forms_info(p_data date, p_linha text, p_tipo text, p_frota text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('hora_motorista', f.hora, 'motorista_forms', f.motorista, 'passageiros_forms', f.passageiros)
  from bi_forms f where f.v_data = p_data and f.v_linha = p_linha and f.v_tipo = p_tipo
    and public.normaliza_tag(coalesce(f.v_frota, '')) = public.normaliza_tag(coalesce(p_frota, ''))
  order by f.recebido_em desc limit 1;
$$;

do $$ begin
  if to_regclass('public.ev_eventos') is not null then
    execute $f$
      create or replace function public._bi_ev_pont_motorista() returns trigger
      language plpgsql security definer set search_path = public as $t$
      declare i jsonb;
      begin
        if new.tipo <> 'pontualidade' then return new; end if;
        i := public._bi_forms_info(new.data, new.linha, new.detalhe->>'tipo', new.frota);
        if i is not null then
          new.detalhe := new.detalhe || i;
          new.titulo := new.titulo || ' · motorista informou ' || (i->>'hora_motorista');
        elsif exists (select 1 from bi_forms where recebido_em > now() - interval '1 day')
              and new.data >= (select min(data) from bi_forms) then
          -- só diz isso se o robô do Forms está rodando (senão seria falso)
          new.titulo := new.titulo || ' · motorista ainda não informou no Forms';
        end if;
        return new;
      end $t$ $f$;
    drop trigger if exists bi_ev_pont_motorista on public.ev_eventos;
    create trigger bi_ev_pont_motorista before insert on public.ev_eventos for each row execute function public._bi_ev_pont_motorista();
  end if;
end $$;

-- Forms que chega depois do evento já criado: completa o detalhe (o título já enviado não muda)
create or replace function public._bi_forms_ev_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.viagem_id is not null and new.casado_em is not null and to_regclass('public.ev_eventos') is not null then
    execute $q$ update ev_eventos e set detalhe = e.detalhe || jsonb_build_object('hora_motorista', $1, 'motorista_forms', $2, 'passageiros_forms', $3)
                where e.tipo = 'pontualidade' and e.data = $4 and e.linha = $5 and e.detalhe->>'tipo' = $6
                  and public.normaliza_tag(coalesce(e.frota, '')) = public.normaliza_tag(coalesce($7, ''))
                  and e.detalhe->>'hora_motorista' is distinct from $1 $q$
      using new.hora, new.motorista, new.passageiros, new.v_data, new.v_linha, new.v_tipo, new.v_frota;
  end if;
  return new;
end $$;
drop trigger if exists bi_forms_ev_depois on public.bi_forms;
create trigger bi_forms_ev_depois after update of casado_em on public.bi_forms for each row execute function public._bi_forms_ev_depois();

grant execute on function public.bi_horarios_motorista(text, date, date), public.bi_justificativa(text, text),
  public.bi_forms_status(text), public.bi_forms_rota_salvar(text, text, text, boolean) to anon;
revoke execute on function public._bi_forms_info(date, text, text, text) from public, anon, authenticated;

-- Conferir depois que o robô rodar:
--   select count(*) total, count(viagem_id) casados from bi_forms;
--   select rota, count(*) from bi_forms where viagem_id is null group by 1 order by 2 desc;
