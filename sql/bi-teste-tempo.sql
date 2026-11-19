-- Teste de tempo dos painéis do BI (rodar no Supabase → SQL Editor → New query → Run).
-- Só LÊ: mede quanto cada painel demora para 1, 7 e 30 dias. O site (anon) tem limite de ~3 s:
-- o que passar de ~2500 ms é o que dá timeout. Não muda nada no banco.
-- (Para medir sem senha, troca o login do BI só dentro deste teste e devolve no fim, na mesma transação.)

create temp table if not exists _bi_teste (painel text, dias int, ms int, ok text);
truncate _bi_teste;

do $do$
declare def text := pg_get_functiondef('public._bi_quem(text)'::regprocedure);
        p text; d int; t0 timestamptz; r text;
begin
  execute $f$create or replace function public._bi_quem(p_token text) returns jsonb language sql as $q$select '{"edita":true,"admin":true}'::jsonb$q$$f$;
  foreach p in array array['ocupacao','fora_rota','custo','nao_cad','viagens','horarios','roteiro'] loop
    foreach d in array array[1, 7, 30] loop
      t0 := clock_timestamp();
      begin
        perform public.bi_dados('teste', p, current_date - (d - 1), current_date, '{}'::jsonb);
        r := 'ok';
      exception when others then r := left(sqlerrm, 120);
      end;
      insert into _bi_teste values (p, d, (extract(epoch from clock_timestamp() - t0) * 1000)::int, r);
    end loop;
  end loop;
  execute def;   -- devolve o login original
end $do$;

select painel, dias, ms,
       case when ok <> 'ok' then 'ERRO: ' || ok when ms > 2500 then 'LENTO (vai dar timeout no site)' when ms > 1500 then 'no limite' else 'ok' end as situacao,
       (select pg_size_pretty(pg_total_relation_size('public.embarques'))) as tamanho_embarques,
       (select count(*) from public.embarques) as linhas_embarques,
       (select pg_size_pretty(pg_total_relation_size('public.viagens'))) as tamanho_viagens,
       (select count(*) from public.viagens) as linhas_viagens,
       (select string_agg(indexname, ', ') from pg_indexes where tablename = 'viagens') as indices_viagens
from _bi_teste order by ms desc;
