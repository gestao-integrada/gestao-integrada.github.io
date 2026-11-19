-- Teste de tempo dos painéis do BI (rodar no Supabase → SQL Editor → New query → Run).
-- Só LÊ: mede quanto cada painel demora para 1, 7, 30 e 90 dias, sem filtro e com Turno = ADM (grupo). O site (anon) tem limite de ~3 s:
-- o que passar de ~2500 ms é o que dá timeout. Não muda nada no banco.
-- (Para medir sem senha, troca o login do BI só dentro deste teste e devolve no fim, na mesma transação.)

drop table if exists _bi_teste;
create temp table _bi_teste (painel text, dias int, filtro text, ms int, ok text);
truncate _bi_teste;

do $do$
declare def text := pg_get_functiondef('public._bi_quem(text)'::regprocedure);
        p text; d int; f text; t0 timestamptz; r text;
begin
  execute $f$create or replace function public._bi_quem(p_token text) returns jsonb language sql as $q$select '{"edita":true,"admin":true}'::jsonb$q$$f$;
  foreach p in array array['ocupacao','fora_rota','custo','nao_cad','viagens','horarios','roteiro','mapa_rotas'] loop
    foreach d in array array[1, 7, 30, 90] loop
    foreach f in array array['{}', '{"tipolinha":"G:ADM"}'] loop
      continue when (p = 'roteiro' and d > 30) or (p = 'horarios' and d > 60);
      t0 := clock_timestamp();
      begin
        perform public.bi_dados('teste', p, current_date - (d - 1), current_date, f::jsonb);
        r := 'ok';
      exception when others then r := left(sqlerrm, 120);
      end;
      insert into _bi_teste values (p, d, case when f = '{}' then 'sem filtro' else 'Turno ADM' end, (extract(epoch from clock_timestamp() - t0) * 1000)::int, r);
    end loop;
    end loop;
  end loop;
  execute def;   -- devolve o login original
end $do$;

select painel, dias, filtro, ms,
       case when ok <> 'ok' then 'ERRO: ' || ok when ms > 2500 then 'LENTO (vai dar timeout no site)' when ms > 1500 then 'no limite' else 'ok' end as situacao,
       (select pg_size_pretty(pg_total_relation_size('public.embarques'))) as tamanho_embarques,
       (select count(*) from public.embarques) as linhas_embarques,
       (select pg_size_pretty(pg_total_relation_size('public.viagens'))) as tamanho_viagens,
       (select count(*) from public.viagens) as linhas_viagens,
       (select string_agg(indexname, ', ') from pg_indexes where tablename = 'viagens') as indices_viagens,
       (select array_to_string(rolconfig, ', ') from pg_roles where rolname = 'anon') as limite_site
from _bi_teste order by ms desc;
