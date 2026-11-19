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

create or replace function public._bi_dds_dia(p_dia date) returns jsonb
language sql stable security definer set search_path = public as $$
with cfg as (select * from bi_config where id = 1),
g as (select t.g, t.o from cfg, jsonb_array_elements(coalesce(cfg.grupos, '[]'::jsonb)) with ordinality as t(g, o)),
vg as (
  select v.ocupacao, upper(trim(v.tipo)) as sent,
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
  'ocupacao', (select jsonb_build_object('viagens', count(*), 'passageiros', coalesce(sum(ocupacao), 0),
                 'media', round(avg(ocupacao)::numeric, 1),
                 'pct', round(100 * avg(ocupacao)::numeric / (select lugares from cfg), 1)) from vg1),
  'ocup_grupos', (select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo, 'viagens', n, 'media', media, 'pct', pct) order by o), '[]'::jsonb) from (
      select vg1.grupo, min(g.o) as o, count(*) as n, round(avg(ocupacao)::numeric, 1) as media,
             round(100 * avg(ocupacao)::numeric / (select lugares from cfg), 1) as pct
      from vg1 join g on g.g->>'nome' = vg1.grupo group by vg1.grupo) z),
  'pontualidade', (select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo, 'sentido', sentido, 'medidas', medidas, 'pontuais', pontuais,
                     'atrasadas', atrasadas, 'adiantadas', adiantadas, 'sem_dado', sem_dado, 'pelo_monitor', pelo_monitor,
                     'pct', case when medidas > 0 then round(100.0 * pontuais / medidas, 1) end)
                     order by grupo, sentido), '[]'::jsonb) from pt)
);
$$;
revoke execute on function public._bi_dds_dia(date) from public, anon, authenticated;

-- a página chama esta (login do BI). Devolve o dia escolhido e o dia anterior, para comparar.
create or replace function public.bi_dds(p_token text, p_dia date) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._bi_exige(p_token);
begin
  if p_dia is null then p_dia := _bi_hoje(); end if;
  return json_build_object(
    'atual', public._bi_dds_dia(p_dia),
    'anterior', public._bi_dds_dia(p_dia - 1),
    'cercas', (select count(*) from bi_cercas where ativo and finalidade = 'turno'),
    'coleta', (select max(coletado_em) from viagens),
    'excluir', (select dds_excluir from bi_config where id = 1));
end $$;
grant execute on function public.bi_dds(text, date) to anon, authenticated;
