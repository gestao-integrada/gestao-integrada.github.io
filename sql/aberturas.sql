-- =====================================================================
-- ABERTURAS ERRADAS DE VIAGEM (página gestao-integrada.github.io/aberturas/)
-- Olha as viagens que a coleta da TFleet grava na tabela viagens e aponta
-- as que o motorista abriu errado no app de apontamento:
--   1 SENTIDO        ADM aberta como IDA à tarde (era VOLTA) ou VOLTA de manhã (era IDA);
--                    turno com horário de outro sentido.
--   2 ROTA ESPECIAL  rota que, em certo horário, tem outro nome (CT7 às 7h = CT7 INTERNO).
--   3 REPETIDA       mesmo carro abriu a mesma rota e sentido 2 vezes no dia.
--   4 ROTA DUPLICADA mesma rota e sentido aberta por 2 carros no mesmo período:
--                    o carro que não costuma fazer essa rota provavelmente abriu a rota errada.
--   5 DUAS ROTAS     mesmo carro abriu 2 rotas diferentes no mesmo sentido em menos de 1 h.
--   6 DOIS CARROS    mesmo motorista aparece em 2 carros ao mesmo tempo (login de outro?).
-- Todo dia (hora em abt_config.hora_aviso) os casos novos dos dias anteriores vão para
-- UMA demanda da Caliman no quadro Demandas (e-mail com planilha anexa pelo robô do quadro).
-- Enquanto essa demanda não for marcada Entregue/Cancelado, os casos novos entram nela.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo.
-- Depende de: lotacao.sql (tabela viagens) e solicitacoes.sql (quadro Demandas, mesma senha).
-- =====================================================================

-- ---------------------------------------------------------------- tabelas
create table if not exists public.abt_config (
  id                 int primary key default 1 check (id = 1),
  ativo              boolean not null default true,     -- desligado: só mostra no painel, não cria demanda
  fornecedor         text not null default 'CALIMAN',   -- fornecedor da demanda no quadro
  emails             text[] not null default '{}',      -- quem recebe o e-mail da demanda (Caliman)
  emails_cc          text[] not null default '{}',      -- cópia (você, supervisão)
  hora_aviso         int not null default 9,            -- hora de Belém em que manda os casos novos
  ida_tarde_apos     time not null default '11:00',     -- ADM: IDA depois disso = devia ser VOLTA
  volta_manha_antes  time not null default '10:00',     -- ADM: VOLTA antes disso = devia ser IDA
  sem_regra_sentido  text[] not null default '{APRENDIZ%,EXTRA%,IN HAUS%}',  -- linhas com horário próprio
  min_dois_carros    int not null default 30,           -- motorista em 2 carros com saídas a menos de X min
  min_duas_rotas     int not null default 60,           -- carro com 2 rotas no mesmo sentido em menos de X min
  ultimo_envio       date
);
insert into public.abt_config (id) values (1) on conflict (id) do nothing;

-- rotas que em certo horário têm outro nome (a 2ª abertura do CT7 às 7h é o CT7 INTERNO)
create table if not exists public.abt_especiais (
  id        bigserial primary key,
  linha     text not null,           -- parte do nome da linha como vem da TFleet (ex.: CT7)
  tipo      text,                    -- IDA / VOLTA / vazio = os dois
  das       time not null,
  ate       time not null,
  correta   text not null,           -- como deveria ter sido aberta
  ativo     boolean not null default true
);
insert into public.abt_especiais (linha, tipo, das, ate, correta)
select 'CT7', 'IDA', '06:30', '08:30', 'CT7 INTERNO'
where not exists (select 1 from public.abt_especiais);

-- casos já vistos (1 linha por viagem + regra): guarda se foi avisado, em qual demanda e a tratativa
create table if not exists public.abt_casos (
  viagem_id    text not null,
  regra        text not null,
  data_local   date not null,
  hora         time,
  frota        text,
  motorista    text,
  linha        text,
  tipo         text,
  tipolinha    text,
  ocupacao     int,
  gravidade    text,
  problema     text,
  sugestao     text,
  detectado_em timestamptz not null default now(),
  avisado_em   timestamptz,
  cartao_id    bigint,
  situacao     text not null default 'aberto' check (situacao in ('aberto','orientado','corrigido','falso')),
  obs          text,
  marcado_por  text,
  marcado_em   timestamptz,
  primary key (viagem_id, regra)
);
create index if not exists abt_casos_data on public.abt_casos (data_local desc);
alter table public.abt_casos drop constraint if exists abt_casos_situacao_check;
alter table public.abt_casos add constraint abt_casos_situacao_check check (situacao in ('aberto','orientado','corrigido','falso'));

alter table public.abt_config    enable row level security;   -- sem policy: só pelas funções
alter table public.abt_especiais enable row level security;
alter table public.abt_casos     enable row level security;
revoke all on public.abt_config, public.abt_especiais, public.abt_casos from anon, authenticated;

-- ---------------------------------------------------------------- auxiliares
create or replace function public._abt_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Belem')::date $$;

create or replace function public._abt_lin(p text) returns text
language sql immutable as $$ select regexp_replace(upper(trim(coalesce(p, ''))), '\s+', ' ', 'g') $$;

-- rotas escolhidas em "Rotas vigiadas" na página Visitas aos carros (mesma lista das idas que não subiram).
-- Devolve as linhas normalizadas; null = nenhuma escolhida (ou Visitas não instalada) → olha todas.
create or replace function public._abt_vigiadas() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r text[];
begin
  if to_regclass('public.vis_rotas_vigiadas') is null then return null; end if;
  execute 'select array_agg(distinct public._abt_lin(linha)) from public.vis_rotas_vigiadas' into r;
  return r;
end $$;

-- ---------------------------------------------------------------- detecção
-- Devolve 1 linha por viagem + regra no período. Usa 30 dias antes para aprender o costume
-- de cada motorista (rota mais feita) e o horário normal de cada rota de turno.
drop function if exists public.abt_detectar(date, date);
create or replace function public.abt_detectar(p_de date, p_ate date)
returns table (viagem_id text, regra text, gravidade text, data_local date, hora time, frota text, motorista text,
               linha text, tipo text, tipolinha text, ocupacao int, problema text, sugestao text)
language sql stable security definer set search_path = public as $$
with cfg as (select * from abt_config where id = 1),
base as (
  select v.id, v.data_local, v.hora_saida as hora, v.saida_ts, v.chegada_ts, trim(v.frota) as frota,
         upper(trim(v.motorista)) as motorista, _abt_lin(v.linha) as linha, upper(trim(v.tipo)) as tipo,
         upper(trim(coalesce(v.tipolinha, ''))) as tipolinha, v.ocupacao,
         case when v.hora_saida < '11:00' then 'M' else 'T' end as per
  from (select distinct on (coalesce(x.frota, x.placa), x.saida_ts) x.*      -- se a TFleet corrigiu o sentido/rota,
          from viagens x                                                      -- vale só a versão mais nova da viagem
         where x.data_local between p_de - 30 and p_ate
         order by coalesce(x.frota, x.placa), x.saida_ts, x.coletado_em desc) v
  where v.linha is not null and v.hora_saida is not null and v.tipo is not null
),
-- costume: quantas vezes cada motorista fez cada linha (mesmo grupo) nos 30 dias
cost as (
  select motorista, tipolinha, linha, count(*) as n,
         sum(count(*)) over (partition by motorista, tipolinha) as tot,
         row_number() over (partition by motorista, tipolinha order by count(*) desc, linha) as rk
  from base where motorista <> '' group by 1, 2, 3
),
-- horário normal (mediana em minutos) de cada linha + grupo + sentido
med as (
  select linha, tipolinha, tipo, count(*) as n,
         percentile_cont(0.5) within group (order by extract(epoch from hora) / 60) as m
  from base group by 1, 2, 3
),
v as (                       -- só o período pedido, com o sentido "corrigido" pelas regras de horário
  select b.*,
    case
      when b.tipolinha like 'ADM%' and not (b.linha like any (cfg.sem_regra_sentido)) then
        case when b.tipo = 'IDA' and b.hora >= cfg.ida_tarde_apos then 'VOLTA'
             when b.tipo = 'VOLTA' and b.hora < cfg.volta_manha_antes then 'IDA' end
      when b.tipolinha like 'TURNO%' then
        (select case when abs(extract(epoch from b.hora) / 60 - o.m) + 60 < abs(extract(epoch from b.hora) / 60 - s.m)
                      and abs(extract(epoch from b.hora) / 60 - s.m) > 150 then o.tipo end
           from med s join med o on o.linha = s.linha and o.tipolinha = s.tipolinha and o.tipo <> s.tipo and o.n >= 3
          where s.linha = b.linha and s.tipolinha = b.tipolinha and s.tipo = b.tipo and s.n >= 3 limit 1)
    end as tipo_certo
  from base b cross join cfg
  where b.data_local between p_de and p_ate
    -- abriu a rota errada SEM ler ninguém, fechou e abriu a certa logo depois: o motorista corrigiu, não é erro
    and not (coalesce(b.ocupacao, 0) = 0 and exists (
          select 1 from base c where c.data_local = b.data_local and c.frota = b.frota and c.tipo = b.tipo
             and c.tipolinha = b.tipolinha and c.linha <> b.linha and c.saida_ts > b.saida_ts
             and c.saida_ts - b.saida_ts < make_interval(mins => cfg.min_duas_rotas)))
),
v2 as (select v.*, coalesce(v.tipo_certo, v.tipo) as tipo_ef,
              case when coalesce(v.tipo_certo, v.tipo) = 'IDA' and v.tipolinha like 'ADM%' then 'M'
                   when coalesce(v.tipo_certo, v.tipo) = 'VOLTA' and v.tipolinha like 'ADM%' then 'T'
                   else v.per end as per_ef
       from v),
hab as (select motorista, tipolinha, linha as habitual, n, tot from cost where rk = 1),
r1 as (
  select v.id, '1 SENTIDO' as regra, 'alta' as grav,
         v.tipo || ' aberta às ' || to_char(v.hora, 'HH24:MI') ||
           case when v.tipolinha like 'ADM%' then case when v.tipo = 'IDA' then ' (à tarde)' else ' (de manhã)' end
                else ' (horário de ' || v.tipo_certo || ' nesse turno)' end as problema,
         'Deveria ser ' || v.tipo_certo || '. Do jeito que está, a rota aparece como se tivesse ido 2 vezes.' as sugestao
  from v where v.tipo_certo is not null
),
r2 as (
  select v.id, '2 ROTA ESPECIAL', 'alta',
         v.linha || ' ' || v.tipo || ' aberta às ' || to_char(v.hora, 'HH24:MI'),
         'Nesse horário deveria ser aberta como ' || e.correta || '.'
  from v join abt_especiais e on e.ativo and v.linha like '%' || _abt_lin(e.linha) || '%'
   and (e.tipo is null or upper(e.tipo) = v.tipo) and v.hora between e.das and e.ate
),
r3 as (                      -- 2ª abertura da mesma rota + sentido no mesmo carro (a especial já explica, não repete)
  select x.id, '3 REPETIDA', 'alta',
         'Mesmo carro abriu ' || x.linha || ' ' || x.tipo || ' de novo (a 1ª foi às ' || to_char(x.primeira, 'HH24:MI') || ')',
         'Uma das duas aberturas está errada (sentido ou rota). Conferir qual o carro realmente fez.'
  from (select v.*, row_number() over w as n, first_value(v.hora) over w as primeira
          from v window w as (partition by v.data_local, v.frota, v.linha, v.tipolinha, v.tipo order by v.hora)) x
  where x.n > 1 and not exists (select 1 from r2 where r2.id = x.id)
),
grp as (                     -- mesma rota + sentido (corrigido) + período, carros diferentes
  select v2.*, (min(v2.frota) over pp <> max(v2.frota) over pp) as varios,
         coalesce(c.n::numeric / nullif(c.tot, 0), 0) as costume
  from v2 left join cost c on c.motorista = v2.motorista and c.tipolinha = v2.tipolinha and c.linha = v2.linha
  window pp as (partition by v2.data_local, v2.linha, v2.tipolinha, v2.tipo_ef, v2.per_ef)
),
dono as (
  select distinct on (data_local, linha, tipolinha, tipo_ef, per_ef) id as dono_id, data_local, linha, tipolinha, tipo_ef, per_ef
  from grp where varios
  order by data_local, linha, tipolinha, tipo_ef, per_ef, costume desc, coalesce(ocupacao, 0) desc, hora
),
r4 as (
  select g.id, '4 ROTA DUPLICADA', 'media',
         'A mesma rota (' || g.linha || ' ' || g.tipo_ef || ') também foi aberta pelo carro ' ||
           (select string_agg(o.frota || ' (' || coalesce(initcap(split_part(o.motorista, ' ', 1)), '?') || ' ' || to_char(o.hora, 'HH24:MI') || ')', ', ' order by o.hora)
              from grp o where o.data_local = g.data_local and o.linha = g.linha and o.tipolinha = g.tipolinha
               and o.tipo_ef = g.tipo_ef and o.per_ef = g.per_ef and o.frota <> g.frota),
         case when coalesce(op.linha, h.habitual) is not null and coalesce(op.linha, h.habitual) <> g.linha then
           'Provável rota errada: ' ||
           case when op.linha is not null and op.linha <> g.linha
                then 'na ' || op.tipo_ef || ' o mesmo carro e motorista abriram ' || op.linha
                else 'esse motorista costuma fazer ' || h.habitual end ||
           case when not exists (select 1 from v2 z where z.data_local = g.data_local and z.linha = coalesce(op.linha, h.habitual)
                                  and z.tipolinha = g.tipolinha and z.tipo_ef = g.tipo_ef and z.per_ef = g.per_ef)
                then ', que ficou SEM ' || g.tipo_ef || ' nesse dia.' else '.' end
         else 'Dois carros na mesma rota e sentido: conferir se um deles era outra rota (ou se foi carro extra).' end
  from grp g join dono d on d.data_local = g.data_local and d.linha = g.linha and d.tipolinha = g.tipolinha
                         and d.tipo_ef = g.tipo_ef and d.per_ef = g.per_ef and d.dono_id <> g.id
  left join hab h on h.motorista = g.motorista and h.tipolinha = g.tipolinha
  left join lateral (select o.linha, o.tipo_ef from v2 o           -- o que o mesmo carro/motorista abriu no outro sentido do dia
                      where o.data_local = g.data_local and o.frota = g.frota and o.motorista = g.motorista
                        and o.tipolinha = g.tipolinha and o.tipo_ef <> g.tipo_ef order by o.hora limit 1) op on g.tipolinha like 'ADM%'
  where g.frota <> (select frota from grp where id = d.dono_id)
),
r5 as (                      -- mesmo carro, 2 rotas diferentes no mesmo sentido, em menos de X min: a 1ª costuma ser a errada
  select a.id, '5 DUAS ROTAS', 'media',
         'Abriu ' || a.linha || ' ' || a.tipo || ' às ' || to_char(a.hora, 'HH24:MI') || ' e leu ' || a.ocupacao || ' passageiro(s); '
           || extract(minute from b.saida_ts - a.saida_ts)::int + 60 * extract(hour from b.saida_ts - a.saida_ts)::int
           || ' min depois fechou e abriu ' || b.linha || ' (' || to_char(b.hora, 'HH24:MI') || ')',
         case when h.habitual = a.linha
              then 'Conferir a 2ª abertura (' || b.linha || '): o motorista costuma fazer ' || a.linha || '.'
              else 'Abriu a rota errada primeiro e corrigiu, mas os ' || a.ocupacao || ' passageiro(s) lidos ficaram contados em ' || a.linha
                   || '. Acertar na TFleet (passar para ' || b.linha || ').' end
  from v a join v b on b.data_local = a.data_local and b.frota = a.frota and b.tipo = a.tipo and b.tipolinha = a.tipolinha
   and b.linha <> a.linha and b.saida_ts > a.saida_ts
   and b.saida_ts - a.saida_ts < make_interval(mins => (select min_duas_rotas from cfg))
   and coalesce(a.ocupacao, 0) > 0
  left join hab h on h.motorista = a.motorista and h.tipolinha = a.tipolinha
),
r6 as (                      -- mesmo motorista em 2 carros ao mesmo tempo
  select b.id, '6 DOIS CARROS', 'verificar',
         initcap(b.motorista) || ' já estava no carro ' || a.frota || ' (' || a.linha || ' ' || a.tipo || ' às ' || to_char(a.hora, 'HH24:MI') || ')',
         'O mesmo motorista não dirige 2 carros juntos: provável login de outro motorista neste carro.'
  from v a join v b on b.motorista = a.motorista and a.motorista <> '' and b.frota <> a.frota and b.saida_ts > a.saida_ts
   and case when a.chegada_ts is not null then b.saida_ts < a.chegada_ts
            else b.saida_ts - a.saida_ts < make_interval(mins => (select min_dois_carros from cfg)) end
),
todas as (select * from r1 union all select * from r2 union all select * from r3
          union all select * from r4 union all select * from r5 union all select * from r6)
select t.id, t.regra, t.grav, v.data_local, v.hora, v.frota, v.motorista, v.linha, v.tipo, v.tipolinha, v.ocupacao,
       t.problema, t.sugestao
from todas t join v on v.id = t.id
cross join (select public._abt_vigiadas() as l) vg
where vg.l is null or v.linha = any (vg.l)          -- só as rotas escolhidas em "Rotas vigiadas" (Visitas)
order by v.data_local desc, v.hora, t.regra;
$$;
revoke execute on function public.abt_detectar(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- registrar + avisar (roda sozinho de hora em hora)
-- 1) grava os casos novos dos últimos p_dias;
-- 2) depois da hora_aviso, 1 vez por dia: casos de dias ANTERIORES ainda não avisados →
--    demanda da Caliman no quadro (cria, ou soma na que está aberta) + e-mail com planilha.
create or replace function public.abt_rodar(p_dias int default 3, p_forcar boolean default false) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  cfg abt_config; hoje date := _abt_hoje(); novos int; n int; c sol_cartoes; eid bigint; aid bigint;
  lista text; csv text; per text; assunto text; corpo text; cid bigint; criou boolean := false; b bytea;
begin
  select * into cfg from abt_config where id = 1;
  insert into abt_casos (viagem_id, regra, data_local, hora, frota, motorista, linha, tipo, tipolinha, ocupacao,
                         gravidade, problema, sugestao)
  select d.viagem_id, d.regra, d.data_local, d.hora, d.frota, d.motorista, d.linha, d.tipo, d.tipolinha, d.ocupacao,
         d.gravidade, d.problema, d.sugestao
  from abt_detectar(hoje - greatest(p_dias, 0), hoje) d
  on conflict (viagem_id, regra) do update set problema = excluded.problema, sugestao = excluded.sugestao,
     ocupacao = excluded.ocupacao, motorista = excluded.motorista
  where abt_casos.avisado_em is null;
  get diagnostics novos = row_count;

  if not cfg.ativo or to_regclass('public.sol_cartoes') is null then return novos || ' caso(s) gravado(s); aviso desligado.'; end if;
  if not p_forcar and (cfg.ultimo_envio = hoje or extract(hour from now() at time zone 'America/Belem') < cfg.hora_aviso) then
    return novos || ' caso(s) gravado(s).';
  end if;

  select count(*), min(data_local)::text || ' a ' || max(data_local)::text into n, per
    from abt_casos where avisado_em is null and situacao = 'aberto' and data_local < hoje;
  update abt_config set ultimo_envio = hoje where id = 1;
  if n = 0 then return novos || ' caso(s) gravado(s); nada novo para avisar.'; end if;

  -- 1 linha por viagem (junta as regras da mesma viagem)
  with x as (
    select data_local, hora, frota, motorista, linha, tipo, ocupacao,
           string_agg(problema, ' · ' order by regra) as problema,
           (array_agg(sugestao order by regra))[1] as sugestao
    from abt_casos where avisado_em is null and situacao = 'aberto' and data_local < hoje
    group by viagem_id, data_local, hora, frota, motorista, linha, tipo, ocupacao)
  select string_agg('• ' || to_char(data_local, 'DD/MM') || ' ' || to_char(hora, 'HH24:MI') || ' · carro ' || frota || ' · ' ||
                    coalesce(initcap(motorista), '?') || chr(10) || '  ' || linha || ' ' || tipo ||
                    coalesce(' (' || ocupacao || ' pass.)', '') || chr(10) || '  ' || problema || chr(10) || '  → ' || sugestao,
                    chr(10) || chr(10) order by data_local, hora),
         count(*)
    into lista, n from x;
  per := (select to_char(min(data_local), 'DD/MM') || case when min(data_local) <> max(data_local) then ' a ' || to_char(max(data_local), 'DD/MM') else '' end
            from abt_casos where avisado_em is null and situacao = 'aberto' and data_local < hoje);

  csv := E'﻿' || 'Data;Hora;Carro;Motorista;Rota;Sentido;Grupo;Passageiros;Regra;Problema;O que fazer' || chr(13) || chr(10) ||
    (select string_agg(concat_ws(';', to_char(data_local, 'DD/MM/YYYY'), to_char(hora, 'HH24:MI'), frota, motorista, linha, tipo, tipolinha,
                       coalesce(ocupacao::text, ''), regra, replace(problema, ';', ','), replace(sugestao, ';', ',')), chr(13) || chr(10)
                       order by data_local, hora, regra)
       from abt_casos where avisado_em is null and situacao = 'aberto' and data_local < hoje);

  -- demanda aberta do robô para esse fornecedor? soma nela; senão cria
  select * into c from sol_cartoes where criado_por = 'Robô aberturas' and lower(fornecedor) = lower(cfg.fornecedor)
     and status not in ('Entregue', 'Cancelado') order by id desc limit 1;
  if c.id is null then
    insert into sol_cartoes (fornecedor, assunto, descricao, status, emails, criado_por, ultimo_contato)
    values (cfg.fornecedor, 'Viagens abertas erradas no app (motoristas)',
      'Viagens abertas no app de apontamento com sentido, rota ou horário errados. Isso conta passageiros na rota errada '
      || 'e faz a rota aparecer como se tivesse ido 2 vezes (ou não ter ido).' || chr(10) || chr(10)
      || 'Pedimos à Caliman: (1) orientar os motoristas da lista, (2) dizer como vai tratar e (3) até quando. '
      || 'Os casos novos entram nesta mesma demanda até ela ser marcada como Entregue.',
      'Enviado', _sol_emails_limpos(cfg.emails || cfg.emails_cc), 'Robô aberturas', hoje)
    returning * into c;
    insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, 'Robô aberturas', 'criou', 'Demanda criada automaticamente');
    criou := true;
  end if;
  insert into sol_historico (cartao_id, quem, tipo, texto, dados) values (c.id, 'Robô aberturas', 'comentario',
    n || ' viagem(ns) aberta(s) errada(s) em ' || per || ':' || chr(10) || chr(10) || lista,
    jsonb_build_object('casos', n, 'periodo', per));

  -- e-mail (o robô do quadro manda) com a planilha
  if cardinality(_sol_emails_limpos(cfg.emails || cfg.emails_cc)) > 0 then
    assunto := 'Viagens abertas erradas no app – ' || per || ' (' || n || ')';
    corpo := 'Bom dia,' || chr(10) || chr(10) ||
      'Encontramos ' || n || ' viagem(ns) aberta(s) errada(s) no app de apontamento em ' || per || '. ' ||
      'Elas contam passageiros na rota ou no sentido errado e deixam o BDV inconsistente.' || chr(10) || chr(10) ||
      lista || chr(10) || chr(10) ||
      'Pedimos, por favor:' || chr(10) ||
      '1. Orientar os motoristas citados (ida de manhã / volta à tarde no ADM; CT7 das 7h = CT7 INTERNO; abrir a rota que realmente vai fazer).' || chr(10) ||
      '2. Responder como vão tratar e até quando (prazo) — pode ser direto na demanda, pelo link abaixo.' || chr(10) ||
      '3. Se algum caso estiver certo (ex.: carro extra), avisar para tirarmos da lista.' || chr(10) || chr(10) ||
      'A planilha com todos os casos vai em anexo.';
    insert into sol_emails (cartao_id, para, cc, assunto, corpo, criado_por)
    values (c.id, _sol_emails_limpos(cfg.emails), _sol_emails_limpos(cfg.emails_cc), assunto, corpo, 'Robô aberturas')
    returning id into eid;
    b := convert_to(csv, 'UTF8');
    insert into sol_anexos (cartao_id, email_id, nome, tipo, tamanho, dados, enviado_por)
    values (c.id, eid, 'aberturas-erradas-' || replace(replace(per, '/', '-'), ' ', '_') || '.csv', 'text/csv', length(b), b, 'Robô aberturas')
    returning id into aid;
    insert into sol_email_anexos (email_id, anexo_id) values (eid, aid);
    insert into sol_historico (cartao_id, quem, tipo, texto) values (c.id, 'Robô aberturas', 'email', 'E-mail: ' || assunto);
  end if;
  update sol_cartoes set ultimo_contato = hoje, atualizado_em = now(),
    status = case when status = 'Sem resposta' then 'Enviado' else status end where id = c.id;

  -- WhatsApp para quem tem celular nos contatos da demanda (se a fila do quadro existir)
  begin
    perform _sol_whats_fila(c.id, _sol_whats_para(c),
      _sol_whats_msg(c, '🚌 *' || n || ' viagem(ns) aberta(s) errada(s)* em ' || per,
                     'A lista está na demanda. Pedimos orientar os motoristas e informar como e até quando vão tratar.'));
  exception when others then null;
  end;

  update abt_casos set avisado_em = now(), cartao_id = c.id
   where avisado_em is null and situacao = 'aberto' and data_local < hoje;
  return novos || ' caso(s) gravado(s); ' || n || ' viagem(ns) avisada(s) na demanda ' || c.id || case when criou then ' (nova)' else '' end || '.';
end $$;
revoke execute on function public.abt_rodar(int, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- painel (mesma senha do quadro Demandas)
create or replace function public._abt_exige(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  if q->>'tipo' <> 'interno' then raise exception 'Este painel é só da equipe.'; end if;
  return q;
end $$;
revoke execute on function public._abt_exige(text) from public, anon, authenticated;

-- dados do painel (usado pelo painel /aberturas/ e pela página Visitas aos carros)
-- p_caliman = true: esconde os casos marcados "estava certa" e os e-mails dos ajustes
create or replace function public._abt_dados(de date, ate date, p_caliman boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if ate - de > 62 then raise exception 'Escolha um período de até 2 meses.'; end if;
  return jsonb_build_object(
    'de', de, 'ate', ate, 'hoje', _abt_hoje(),
    'casos', (select coalesce(jsonb_agg(jsonb_build_object(
        'viagem_id', d.viagem_id, 'regra', d.regra, 'gravidade', d.gravidade, 'data', d.data_local, 'hora', to_char(d.hora, 'HH24:MI'),
        'frota', d.frota, 'motorista', d.motorista, 'linha', d.linha, 'tipo', d.tipo, 'tipolinha', d.tipolinha,
        'ocupacao', d.ocupacao, 'problema', d.problema, 'sugestao', d.sugestao,
        'situacao', coalesce(c.situacao, 'aberto'), 'obs', c.obs, 'marcado_por', c.marcado_por,
        'avisado_em', c.avisado_em, 'cartao_id', c.cartao_id) order by d.data_local desc, d.hora desc), '[]'::jsonb)
      from abt_detectar(de, ate) d left join abt_casos c on c.viagem_id = d.viagem_id and c.regra = d.regra
      where not (p_caliman and coalesce(c.situacao, 'aberto') = 'falso')),
    'viagens', (select count(*) from viagens, (select _abt_vigiadas() as l) vg where data_local between de and ate
                  and (vg.l is null or _abt_lin(linha) = any (vg.l))),
    'rotas_vigiadas', coalesce(cardinality(_abt_vigiadas()), 0),
    'coleta', (select max(coletado_em) from viagens),
    'demanda', (select jsonb_build_object('id', s.id, 'status', s.status, 'prazo', s.prazo, 'responsavel', s.responsavel,
                  'link', _sol_link(s)) from sol_cartoes s where s.criado_por = 'Robô aberturas' order by s.id desc limit 1),
    'config', (select jsonb_build_object('ativo', ativo, 'fornecedor', fornecedor, 'hora_aviso', hora_aviso, 'ultimo_envio', ultimo_envio,
                  'especiais', (select coalesce(jsonb_agg(to_jsonb(e) order by e.id), '[]'::jsonb) from abt_especiais e))
                  || case when p_caliman then '{}'::jsonb else jsonb_build_object('emails', emails, 'emails_cc', emails_cc) end
               from abt_config where id = 1));
end $$;
revoke execute on function public._abt_dados(date, date, boolean) from public, anon, authenticated;

create or replace function public.abt_painel(p_token text, p_de date default null, p_ate date default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := _abt_exige(p_token);
begin
  return (jsonb_build_object('quem', q) || _abt_dados(coalesce(p_de, _abt_hoje() - 6), coalesce(p_ate, _abt_hoje())))::json;
end $$;

-- página Visitas aos carros: Caliman (celular/matrícula) e equipe (senha do Demandas) veem; só a equipe marca
create or replace function public.abt_visitas(p_token text, p_de date default null, p_ate date default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb;
begin
  if to_regprocedure('public._vis_exige(text,text)') is null then raise exception 'Página Visitas não instalada.'; end if;
  execute 'select public._vis_exige($1, null)' into q using p_token;
  return (jsonb_build_object('quem', q) || _abt_dados(coalesce(p_de, _abt_hoje() - 6), coalesce(p_ate, _abt_hoje()),
          q->>'tipo' <> 'equipe'))::json;
end $$;

-- marcar um caso: corrigido (a Caliman/TFleet ajustou) · falso (estava certo, ex. carro extra) · aberto (desfazer)
create or replace function public.abt_marcar(p_token text, p_viagem text, p_regra text, p_situacao text, p_obs text default null) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := _abt_exige(p_token); d record;
begin
  if p_situacao not in ('aberto', 'orientado', 'corrigido', 'falso') then raise exception 'Situação inválida.'; end if;
  if not exists (select 1 from abt_casos where viagem_id = p_viagem and regra = p_regra) then
    select * into d from abt_detectar((select data_local from viagens where id = p_viagem), (select data_local from viagens where id = p_viagem)) x
     where x.viagem_id = p_viagem and x.regra = p_regra;
    if d.viagem_id is null then raise exception 'Caso não encontrado.'; end if;
    insert into abt_casos (viagem_id, regra, data_local, hora, frota, motorista, linha, tipo, tipolinha, ocupacao, gravidade, problema, sugestao)
    values (d.viagem_id, d.regra, d.data_local, d.hora, d.frota, d.motorista, d.linha, d.tipo, d.tipolinha, d.ocupacao, d.gravidade, d.problema, d.sugestao);
  end if;
  update abt_casos set situacao = p_situacao, obs = nullif(trim(coalesce(p_obs, '')), ''), marcado_por = q->>'nome', marcado_em = now()
   where viagem_id = p_viagem and regra = p_regra;
  return 'ok';
end $$;

-- tratativa de uma viagem (todas as regras dela), pela página Visitas aos carros ou pelo painel:
--   orientado = conversou com o motorista · corrigido = acertado na TFleet · falso = estava certa (só equipe) · aberto = desfazer
-- justificativa obrigatória (menos para reabrir). Se a viagem já foi para a demanda, a tratativa entra como comentário nela.
create or replace function public.abt_tratar(p_token text, p_viagem text, p_situacao text, p_obs text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb; quem text; eq boolean; d record; n int := 0; cid bigint; txt text;
begin
  if p_token like 'tfv_%' then
    execute 'select public._vis_exige($1, null)' into q using p_token;
    eq := q->>'tipo' = 'equipe';
  else
    q := _abt_exige(p_token); eq := true;
  end if;
  quem := (q->>'nome') || case when eq then '' else ' (' || coalesce(nullif(q->>'empresa', ''), 'Caliman') || ')' end;
  if p_situacao not in ('aberto', 'orientado', 'corrigido', 'falso') then raise exception 'Escolha o que foi feito.'; end if;
  if p_situacao = 'falso' and not eq then raise exception 'Só a equipe marca que a viagem estava certa. Explique na justificativa.'; end if;
  if p_situacao <> 'aberto' and length(trim(coalesce(p_obs, ''))) < 5 then raise exception 'Escreva a justificativa (o que foi feito).'; end if;
  -- grava os casos da viagem que ainda não estão na tabela
  for d in select * from abt_detectar((select data_local from viagens where id = p_viagem), (select data_local from viagens where id = p_viagem)) x
            where x.viagem_id = p_viagem loop
    insert into abt_casos (viagem_id, regra, data_local, hora, frota, motorista, linha, tipo, tipolinha, ocupacao, gravidade, problema, sugestao)
    values (d.viagem_id, d.regra, d.data_local, d.hora, d.frota, d.motorista, d.linha, d.tipo, d.tipolinha, d.ocupacao, d.gravidade, d.problema, d.sugestao)
    on conflict do nothing;
  end loop;
  update abt_casos set situacao = p_situacao, obs = nullif(trim(coalesce(p_obs, '')), ''), marcado_por = quem, marcado_em = now()
   where viagem_id = p_viagem;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Viagem não encontrada.'; end if;
  select max(cartao_id), max(to_char(data_local, 'DD/MM') || ' ' || to_char(hora, 'HH24:MI') || ' · carro ' || frota || ' · ' || linha || ' ' || tipo)
    into cid, txt from abt_casos where viagem_id = p_viagem;
  if cid is not null and to_regclass('public.sol_historico') is not null then
    insert into sol_historico (cartao_id, quem, tipo, texto) values (cid, quem, 'comentario',
      'Tratativa da viagem ' || txt || ': ' ||
      case p_situacao when 'orientado' then 'motorista orientado' when 'corrigido' then 'corrigida na TFleet'
                      when 'falso' then 'estava certa' else 'reaberta' end ||
      coalesce(' — ' || nullif(trim(p_obs), ''), ''));
  end if;
  return 'ok';
end $$;

create or replace function public.abt_config_salvar(p_token text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := _abt_exige(p_token); e jsonb;
begin
  if not (q->>'edita')::boolean then raise exception 'Sem permissão para mudar os ajustes.'; end if;
  update abt_config set
    ativo      = coalesce((p_dados->>'ativo')::boolean, ativo),
    fornecedor = coalesce(nullif(trim(p_dados->>'fornecedor'), ''), fornecedor),
    emails     = case when p_dados ? 'emails' then _sol_emails_limpos(array(select jsonb_array_elements_text(p_dados->'emails'))) else emails end,
    emails_cc  = case when p_dados ? 'emails_cc' then _sol_emails_limpos(array(select jsonb_array_elements_text(p_dados->'emails_cc'))) else emails_cc end,
    hora_aviso = coalesce(least(greatest((p_dados->>'hora_aviso')::int, 0), 23), hora_aviso)
  where id = 1;
  if p_dados ? 'especiais' then
    delete from abt_especiais where true;
    for e in select * from jsonb_array_elements(p_dados->'especiais') loop
      if coalesce(trim(e->>'linha'), '') <> '' and coalesce(trim(e->>'correta'), '') <> '' then
        insert into abt_especiais (linha, tipo, das, ate, correta)
        values (trim(e->>'linha'), nullif(upper(trim(e->>'tipo')), ''), (e->>'das')::time, (e->>'ate')::time, trim(e->>'correta'));
      end if;
    end loop;
  end if;
  return 'ok';
end $$;

-- botão "Mandar agora para a Caliman" (não espera a hora do aviso)
create or replace function public.abt_enviar_agora(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare q jsonb := _abt_exige(p_token);
begin
  if not (q->>'edita')::boolean then raise exception 'Sem permissão.'; end if;
  return abt_rodar(3, true);
end $$;

grant execute on function public.abt_painel(text, date, date), public.abt_visitas(text, date, date), public.abt_tratar(text, text, text, text), public.abt_marcar(text, text, text, text, text),
  public.abt_config_salvar(text, jsonb), public.abt_enviar_agora(text) to anon, authenticated;

-- ---------------------------------------------------------------- agendamento (pg_cron): de hora em hora, aos 20 min
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'aberturas-erradas';
select cron.schedule('aberturas-erradas', '20 * * * *', 'select public.abt_rodar()');

select 'Aberturas erradas pronto' as status, (select count(*) from public.abt_especiais) as rotas_especiais;
