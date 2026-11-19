-- DDS do dia: ocupação e pontualidade em porcentagem, para apresentar no projetor.
-- Rodar DEPOIS de sql/bi.sql (usa bi_config, _bi_viagens, _bi_horarios e o login do BI).
-- Página: gestao-integrada.github.io/dds/
--
-- Como cada número é calculado (o mesmo texto aparece na página, em "Como é calculado"):
--   Ocupação  = média de passageiros por viagem ÷ lugares do ônibus (bi_config.lugares, 45).
--               Entram as viagens do dia (IDA e VOLTA) com pelo menos 1 passageiro, das rotas dos grupos de
--               Gerenciar (ADM, Turno 12x12, CT). Fora: INTERNO e linhas com as palavras de dds_excluir (VAN, MICRO).
--   Pontualidade = viagens no horário ÷ viagens com hora medida, por grupo e sentido, pelas cercas dos turnos
--               (mesma regra do painel Horários do BI). Entrada (IDA): chegar ANTES também conta como pontual.
--               Saída (VOLTA): sair antes da tolerância conta como fora do horário.
--               Viagem sem hora (sem Monitor e sem hora da TFleet) não entra na conta, aparece como "sem dado".
--               As linhas de dds_excluir (VAN, MICRO) também ficam fora da pontualidade.
--               Se a mesma viagem cair em mais de uma cerca do mesmo grupo, conta uma vez só (vale a do Monitor).

alter table public.bi_config add column if not exists dds_excluir text not null default 'VAN, MICRO';

-- p_parte: 'ocupacao' | 'pontualidade' | null (tudo). A página pede cada parte numa chamada (limite de ~3 s do Supabase).
drop function if exists public._bi_dds_dia(date);
create or replace function public._bi_dds_dia(p_dia date, p_parte text default null) returns jsonb
language sql stable security definer set search_path = public as $$
with cfg as (select * from bi_config where id = 1),
g as (select t.g, t.o from cfg, jsonb_array_elements(coalesce(cfg.grupos, '[]'::jsonb)) with ordinality as t(g, o)),
vg as (
  select v.ocupacao, upper(trim(v.tipo)) as sent, v.linha, v.tipolinha, v.frota, v.motorista, to_char(v.hora_saida, 'HH24:MI') as hora,
         (select g.g->>'nome' from g where public._bi_linha_ok(v.tipolinha, v.linha, g.g, cfg.dds_excluir) order by g.o limit 1) as grupo
  from _bi_viagens(p_dia, p_dia) v cross join cfg
  where coalesce(v.ocupacao, 0) > 0
),
vg1 as (select * from vg where grupo is not null),
-- uma linha por viagem e grupo (a do Monitor primeiro, depois a mais perto do previsto)
h as (
  select distinct on (x.data, x.frota, x.linha, x.tipo, x.regra) x.*
  from _bi_horarios(p_dia, p_dia) x cross join cfg
  where not exists (select 1 from unnest(string_to_array(cfg.dds_excluir, ',')) e
                    where trim(e) <> '' and public._bi_tem(x.linha, upper(trim(e))))
  order by x.data, x.frota, x.linha, x.tipo, x.regra, (x.origem = 'Monitor') desc, abs(coalesce(x.dif, 9999))
),
pt as (
  select h.regra as grupo, h.tipo as sentido,
         count(*) filter (where h.hora_real is not null) as medidas,
         count(*) filter (where h.status = 'no horário' or (h.status = 'adiantado' and h.tipo = 'IDA')) as pontuais,
         count(*) filter (where h.status = 'atrasado') as atrasadas,
         count(*) filter (where h.status = 'adiantado') as adiantadas,
         count(*) filter (where h.hora_real is null) as sem_dado,
         count(*) filter (where h.origem = 'Monitor') as pelo_monitor
  from h group by 1, 2
)
select jsonb_build_object(
  'dia', p_dia,
  'lugares', (select lugares from cfg),
  'ocupacao', case when p_parte is null or p_parte = 'ocupacao' then (select jsonb_build_object('viagens', count(*), 'passageiros', coalesce(sum(ocupacao), 0),
                 'media', round(avg(ocupacao)::numeric, 1),
                 'pct', round(100 * avg(ocupacao)::numeric / (select lugares from cfg), 1)) from vg1) end,
  'ocup_grupos', case when p_parte is null or p_parte = 'ocupacao' then (select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo, 'viagens', n, 'media', media, 'pct', pct) order by o), '[]'::jsonb) from (
      select vg1.grupo, min(g.o) as o, count(*) as n, round(avg(ocupacao)::numeric, 1) as media,
             round(100 * avg(ocupacao)::numeric / (select lugares from cfg), 1) as pct
      from vg1 join g on g.g->>'nome' = vg1.grupo group by vg1.grupo) z) end,
  'pontualidade', case when p_parte is null or p_parte = 'pontualidade' then (select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo, 'sentido', sentido, 'medidas', medidas, 'pontuais', pontuais,
                     'atrasadas', atrasadas, 'adiantadas', adiantadas, 'sem_dado', sem_dado, 'pelo_monitor', pelo_monitor,
                     'pct', case when medidas > 0 then round(100.0 * pontuais / medidas, 1) end)
                     order by grupo, sentido), '[]'::jsonb) from pt) end,
  -- drill-down (a página só pede quando clica num quadro)
  'det_pont', case when p_parte = 'det_pont' then (select coalesce(jsonb_agg(jsonb_build_object(
                     'grupo', h.regra, 'sentido', h.tipo, 'cerca', h.cerca, 'linha', h.linha, 'frota', h.frota, 'motorista', h.motorista,
                     'prevista', h.prevista, 'real', h.hora_real, 'dif', h.dif, 'status', h.status, 'origem', h.origem,
                     'tol_antes', h.tol_antes, 'tol_depois', h.tol_depois)
                     order by (h.status = 'atrasado') desc, (h.status = 'adiantado' and h.tipo = 'VOLTA') desc,
                              (h.hora_real is null) desc, h.regra, h.tipo, h.prevista, h.linha), '[]'::jsonb) from h) end,
  'det_ocup', case when p_parte = 'det_ocup' then (select coalesce(jsonb_agg(jsonb_build_object(
                     'grupo', grupo, 'linha', linha, 'sentido', sent, 'viagens', n, 'media', media, 'maximo', maximo,
                     'pct', pct, 'carros', carros) order by pct desc, linha), '[]'::jsonb) from (
                 select grupo, linha, sent, count(*) as n, round(avg(ocupacao)::numeric, 1) as media, max(ocupacao) as maximo,
                        round(100 * avg(ocupacao)::numeric / (select lugares from cfg), 1) as pct,
                        string_agg(distinct public.normaliza_tag(frota), ', ') as carros
                 from vg1 group by grupo, linha, sent) z) end
);
$$;
revoke execute on function public._bi_dds_dia(date, text) from public, anon, authenticated;

-- a página chama esta (login do BI). Devolve o dia escolhido e o dia anterior, para comparar.
-- p_parte: info | atual_ocupacao | atual_pontualidade | anterior_ocupacao | anterior_pontualidade
--          | atual_det_pont | atual_det_ocup (drill-down) | null (tudo)
drop function if exists public.bi_dds(text, date);
create or replace function public.bi_dds(p_token text, p_dia date, p_parte text default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token); r jsonb := '{}'::jsonb;
begin
  if p_dia is null then p_dia := _bi_hoje(); end if;
  if p_parte is null or p_parte = 'info' then
    r := r || jsonb_build_object(
      'cercas', (select count(*) from bi_cercas where ativo and finalidade = 'turno'),
      'coleta', (select max(coletado_em) from viagens),
      'excluir', (select dds_excluir from bi_config where id = 1));
  end if;
  if p_parte is null then
    r := r || jsonb_build_object('atual', public._bi_dds_dia(p_dia), 'anterior', public._bi_dds_dia(p_dia - 1));
  elsif p_parte like 'atual\_%' then
    r := r || jsonb_build_object('atual', public._bi_dds_dia(p_dia, substr(p_parte, 7)));
  elsif p_parte like 'anterior\_%' then
    r := r || jsonb_build_object('anterior', public._bi_dds_dia(p_dia - 1, substr(p_parte, 10)));
  end if;
  return r::json;
end $$;
grant execute on function public.bi_dds(text, date, text) to anon, authenticated;
