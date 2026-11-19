-- =====================================================================
-- TELA "HOJE" + FICHA DO ÔNIBUS (página gestao-integrada.github.io/hoje/)
-- Só LÊ o que os outros painéis já gravam. Não cria tabela nem apaga nada.
--   hoje_painel(token)          → o que pede ação agora (ocorrências abertas, celulares sem sinal,
--                                 carregador ruim, aberturas erradas, viagens lotadas, atrasos, visitas)
--   onibus_ficha(token, frota)  → tudo de um carro num lugar só (celular, vistorias, ocorrências,
--                                 viagens/lotação, pontualidade, aberturas, visitas da Caliman)
-- Entrada: a mesma senha do quadro Demandas / senha pessoal da Central (só equipe interna).
-- Cada bloco é independente: se uma parte (ex.: Visitas) não estiver instalada, o bloco volta
-- com "erro" e o resto da tela funciona.
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo.
-- Depende de: solicitacoes.sql (senha). Lê, se existirem: samples/events/device_config (Monitor),
-- ocorrencias, vistorias, viagens (Lotação), abt_* (Aberturas), ev_eventos (Eventos), vis_propostas (Visitas).
-- =====================================================================

create or replace function public._hj_hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Belem')::date $$;

create or replace function public._hj_exige(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._sol_exige(p_token);
begin
  if q->>'tipo' <> 'interno' then raise exception 'Este painel é só da equipe.'; end if;
  return q;
end $$;
revoke execute on function public._hj_exige(text) from public, anon, authenticated;

-- regras da tela (mude aqui se precisar)
create or replace function public._hj_cfg() returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'sem_sinal_min', 2160,      -- celular sem mandar nada há mais que isso (min) = sem sinal (1 dia e meio)
    'sem_sinal_max_dias', 7,    -- parado há mais dias que isso = aparelho desativado, sai da lista
    'lotacao_ideal', 45,        -- passageiros acima disso = viagem lotada (o ônibus tem 45 lugares)
    'lugares', 45,              -- acima disso = superlotada (gente em pé)
    'atraso_dias', 3)           -- pontualidade: eventos dos últimos N dias ainda sem justificativa
$$;

-- últimos dados de cada celular (Monitor), com o nº do carro normalizado
create or replace function public._hj_celulares() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', s.device_id, 'frota', normaliza_tag(s.device_name), 'nome', s.device_name,
           'ts', s.ts, 'min', round(extract(epoch from now() - s.ts) / 60),
           'bateria', s.battery_pct, 'tomada', s.plugged, 'corrente', s.current_ma,
           'hotspot', s.hotspot_on, 'versao', s.app_version,
           'tablet', coalesce(c.config->>'device_type', '') = 'tablet') order by normaliza_tag(s.device_name)), '[]'::jsonb)
  from (with recursive d as (
          select min(device_id) as id from samples
          union all
          select (select min(device_id) from samples where device_id > d.id) from d where d.id is not null)
        select x.* from d cross join lateral (select * from samples where device_id = d.id order by ts desc limit 1) x
        where d.id is not null and x.ts > now() - interval '30 days') s
  left join device_config c on c.device_id = s.device_id
$$;
revoke execute on function public._hj_celulares() from public, anon, authenticated;

-- ---------------------------------------------------------------- tela HOJE
-- p_bloco: a página pede um bloco por vez, em paralelo (o Supabase corta cada chamada em ~3 s).
--   ocorrencias | celulares | aberturas | lotadas | atrasos | visitas   (null = tudo)
drop function if exists public.hoje_painel(text);
drop function if exists public.onibus_ficha(text, text);
create or replace function public.hoje_painel(p_token text, p_bloco text default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._hj_exige(p_token); cfg jsonb := _hj_cfg(); d date := _hj_hoje();
        r jsonb := jsonb_build_object('quem', q, 'hoje', d, 'agora', now(), 'cfg', cfg); x jsonb; cel jsonb;
begin
  -- 1. ocorrências abertas (mesmo filtro da Central: aberta + em andamento)
  if p_bloco is null or p_bloco = 'ocorrencias' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'frota', normaliza_tag(o.tag), 'categoria', o.categoria,
             'problema', o.problema, 'status', o.status, 'prioridade', o.prioridade, 'reincidencias', o.reincidencias,
             'desde', coalesce(o.primeira_msg_em, o.criado_em))
             order by (o.prioridade = 'alta') desc, coalesce(o.primeira_msg_em, o.criado_em)), '[]'::jsonb) into x
      from v_ocorrencias_cruzadas o where o.status in ('aberta', 'em_andamento');
  exception when others then
    begin
      select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'frota', normaliza_tag(o.tag), 'categoria', o.categoria,
               'problema', o.problema, 'status', o.status, 'prioridade', o.urgencia, 'reincidencias', o.reincidencias,
               'desde', coalesce(o.primeira_msg_em, o.criado_em))
               order by (o.urgencia = 'alta') desc, coalesce(o.primeira_msg_em, o.criado_em)), '[]'::jsonb) into x
        from ocorrencias o where o.status in ('aberta', 'em_andamento');
    exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  end;
  r := r || jsonb_build_object('ocorrencias', x);
  end if;

  -- 2. celulares sem sinal (> 1,5 dia, até 7 dias) e 3. carregador ruim nas últimas 24 h (tablet não entra)
  if p_bloco is null or p_bloco = 'celulares' then
  begin
    cel := _hj_celulares();
    select coalesce(jsonb_agg(e order by (e->>'min')::numeric desc), '[]'::jsonb) into x
      from jsonb_array_elements(cel) e
     where (e->>'min')::numeric > (cfg->>'sem_sinal_min')::int
       and (e->>'min')::numeric < (cfg->>'sem_sinal_max_dias')::int * 1440;
    r := r || jsonb_build_object('sem_sinal', x,
      'celulares_total', (select count(*) from jsonb_array_elements(cel) e
                           where (e->>'min')::numeric < (cfg->>'sem_sinal_max_dias')::int * 1440));
    select coalesce(jsonb_agg(jsonb_build_object('device_id', v.device_id, 'frota', normaliza_tag(v.nome), 'nome', v.nome,
             'eventos', v.n, 'tipos', v.tipos, 'ultimo', v.ultimo, 'mensagem', v.msg) order by v.n desc), '[]'::jsonb) into x
      from (select ev.device_id, max(ev.device_name) as nome, count(*) as n, array_agg(distinct ev.type) as tipos,
                   max(ev.ts) as ultimo, (array_agg(ev.message order by ev.ts desc))[1] as msg
              from events ev
              left join device_config c on c.device_id = ev.device_id
             where ev.ts > now() - interval '24 hours' and ev.type in ('carregador_fraco', 'nao_carrega')
               and coalesce(c.config->>'device_type', '') <> 'tablet'
             group by ev.device_id) v;
    r := r || jsonb_build_object('carregador', x);
  exception when others then
    r := r || jsonb_build_object('sem_sinal', jsonb_build_object('erro', sqlerrm), 'carregador', jsonb_build_object('erro', sqlerrm));
  end;
  end if;

  -- 4. aberturas erradas ainda em aberto (últimos 3 dias)
  if p_bloco is null or p_bloco = 'aberturas' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('viagem_id', a.viagem_id, 'regra', a.regra, 'gravidade', a.gravidade,
             'data', a.data_local, 'hora', to_char(a.hora, 'HH24:MI'), 'frota', normaliza_tag(a.frota), 'motorista', a.motorista,
             'linha', a.linha, 'tipo', a.tipo, 'problema', a.problema) order by a.data_local desc, a.hora desc), '[]'::jsonb) into x
      from abt_detectar(d - 2, d) a
      left join abt_casos c on c.viagem_id = a.viagem_id and c.regra = a.regra
     where coalesce(c.situacao, 'aberto') = 'aberto';
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('aberturas', x);
  end if;

  -- 5. viagens lotadas hoje (mais passageiros que lugares)
  if p_bloco is null or p_bloco = 'lotadas' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('frota', normaliza_tag(v.frota), 'linha', v.linha, 'tipo', v.tipo,
             'tipolinha', v.tipolinha, 'empresa', v.empresa, 'hora', to_char(v.hora_saida, 'HH24:MI'), 'ocupacao', v.ocupacao,
             'aberta', v.chegada_ts is null, 'super', v.ocupacao > (cfg->>'lugares')::int)
             order by v.ocupacao desc), '[]'::jsonb) into x
      from viagens v where v.data_local = d and v.ocupacao > (cfg->>'lotacao_ideal')::int;
    r := r || jsonb_build_object('lotadas', x,
      'viagens_hoje', (select jsonb_build_object('total', count(*), 'com_leitura', count(*) filter (where ocupacao > 0),
                         'passageiros', coalesce(sum(ocupacao), 0)) from viagens where data_local = d));
  exception when others then r := r || jsonb_build_object('lotadas', jsonb_build_object('erro', sqlerrm)); end;
  end if;

  -- 6. atrasos: pontualidade (painel Eventos) ainda sem justificativa + passagens atrasadas do piloto de rota hoje
  if p_bloco is null or p_bloco = 'atrasos' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'data', e.data, 'frota', normaliza_tag(e.frota), 'linha', e.linha,
             'empresa', e.empresa, 'titulo', e.titulo, 'situacao', e.situacao, 'prazo', e.prazo,
             'status', e.detalhe->>'status', 'dif', e.detalhe->>'dif') order by e.data desc, e.frota), '[]'::jsonb) into x
      from ev_eventos e
     where e.tipo = 'pontualidade' and e.situacao in ('aguardando', 'refazer') and e.data >= d - (cfg->>'atraso_dias')::int;
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('atrasos', x);
  begin
    select coalesce(jsonb_agg(jsonb_build_object('frota', normaliza_tag(p.onibus), 'rota', coalesce(p.rota_nome, p.rota),
             'ponto', p.ponto_nome, 'previsto', p.previsto, 'chegada', p.chegada, 'atraso_min', p.atraso_min)
             order by p.atraso_min desc), '[]'::jsonb) into x
      from rota_passagens p where p.data = d and p.atraso_min > 10 and not coalesce(p.simulacao, false);
  exception when others then x := '[]'::jsonb; end;
  r := r || jsonb_build_object('atrasos_rota', x);
  end if;

  -- 7. visitas da Caliman: pedidos esperando resposta + combinadas para hoje
  if p_bloco is null or p_bloco = 'visitas' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'autor', v.autor, 'tipo', v.tipo,
             'frotas', (select array_agg(normaliza_tag(t)) from unnest(v.tags) t), 'local', v.local, 'dia', v.dia,
             'hora_ini', to_char(v.hora_ini, 'HH24:MI'), 'hora_fim', to_char(v.hora_fim, 'HH24:MI'),
             'hora_combinada', v.hora_combinada, 'status', v.status, 'recado', v.recado)
             order by v.dia, v.hora_ini nulls last), '[]'::jsonb) into x
      from vis_propostas v
     where v.status = 'pendente' or (v.dia = d and v.status in ('confirmada', 'ciente'));
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('visitas', x);
  end if;

  return r::json;
end $$;
grant execute on function public.hoje_painel(text, text) to anon, authenticated;

-- ---------------------------------------------------------------- FICHA DO ÔNIBUS
-- p_frota null/vazio → só a lista de carros (para a busca)
-- p_bloco: celular | vistorias | ocorrencias | viagens | eventos | aberturas | visitas (null = tudo)
create or replace function public.onibus_ficha(p_token text, p_frota text default null, p_bloco text default null) returns json
language plpgsql security definer set search_path = public as $$
declare q jsonb := public._hj_exige(p_token); cfg jsonb := _hj_cfg(); d date := _hj_hoje();
        f text := normaliza_tag(p_frota); r jsonb; x jsonb := '[]'::jsonb; devs text[];
begin
  -- lista de carros conhecidos (viagens 30 dias + celulares + vistorias 60 dias)
  if p_bloco is null or p_bloco = 'carros' then
  begin
    select coalesce(jsonb_agg(t order by length(t), t), '[]'::jsonb) into x from (
      select normaliza_tag(frota) t from viagens where data_local >= d - 30
      union select e->>'frota' from jsonb_array_elements(_hj_celulares()) e where (e->>'min')::numeric < 7 * 1440
      union select normaliza_tag(tag) from vistorias where data_vistoria >= d - 60) z where t is not null and t <> '00';
  exception when others then x := '[]'::jsonb; end;
  end if;
  r := jsonb_build_object('quem', q, 'hoje', d, 'agora', now(), 'cfg', cfg, 'carros', x, 'frota', f);
  if f is null then return r::json; end if;

  -- celular: última amostra + eventos dos últimos 7 dias (sem os de ruído)
  if p_bloco is null or p_bloco = 'celular' then
  begin
    select coalesce(jsonb_agg(e), '[]'::jsonb) into x from jsonb_array_elements(_hj_celulares()) e where e->>'frota' = f;
    select array_agg(e->>'device_id') into devs from jsonb_array_elements(x) e;
    r := r || jsonb_build_object('celular', x,
      'eventos_celular', (select coalesce(jsonb_agg(jsonb_build_object('ts', ev.ts, 'tipo', ev.type, 'mensagem', ev.message,
                            'bateria', ev.battery_pct) order by ev.ts desc), '[]'::jsonb)
                          from (select * from events ev where ev.device_id = any (coalesce(devs, '{}'))
                                  and ev.ts > now() - interval '7 days'
                                  and ev.type not in ('carregador_conectado', 'carregador_desconectado', 'leitura_carregador', 'resumo_dados')
                                order by ev.ts desc limit 40) ev));
  exception when others then r := r || jsonb_build_object('celular', jsonb_build_object('erro', sqlerrm)); end;
  end if;

  -- vistorias (CHECK BDV): últimas 10
  if p_bloco is null or p_bloco = 'vistorias' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('data', v.data_vistoria, 'ts', v.ts, 'local', v.local, 'status', v.status,
             'resultado', v.resultado, 'vistoriador', v.vistoriador, 'ocorrencias', v.ocorrencias, 'observacao', v.observacao,
             'acao', v.acao, 'fotos', cardinality(v.fotos),
             'nok', array_remove(array[case when v.item_app = 'NOK' then 'App BDV' end, case when v.item_chip = 'NOK' then 'Chip' end,
                     case when v.item_cabo = 'NOK' then 'Cabo/carregador' end, case when v.item_leitor = 'NOK' then 'Leitor' end,
                     case when v.item_suporte = 'NOK' then 'Suporte' end, case when v.item_celular = 'NOK' then 'Celular' end], null))
             order by v.ts desc), '[]'::jsonb) into x
      from (select * from vistorias where normaliza_tag(tag) = f order by ts desc limit 10) v;
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('vistorias', x);
  end if;

  -- ocorrências: abertas + as dos últimos 60 dias
  if p_bloco is null or p_bloco = 'ocorrencias' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'categoria', o.categoria, 'problema', o.problema, 'status', o.status,
             'prioridade', o.urgencia, 'reincidencias', o.reincidencias, 'desde', coalesce(o.primeira_msg_em, o.criado_em),
             'resolvido_em', o.resolvido_em, 'resolvido_por', o.resolvido_por, 'solucao', o.solucao)
             order by (o.status in ('aberta', 'em_andamento')) desc, o.criado_em desc), '[]'::jsonb) into x
      from (select * from ocorrencias o where normaliza_tag(o.tag) = f
              and (o.status in ('aberta', 'em_andamento') or o.criado_em > now() - interval '60 days')
            order by o.criado_em desc limit 30) o;
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('ocorrencias', x);
  end if;

  -- viagens e lotação: últimos 7 dias
  if p_bloco is null or p_bloco = 'viagens' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('data', v.data_local, 'hora', to_char(v.hora_saida, 'HH24:MI'), 'linha', v.linha,
             'tipo', v.tipo, 'tipolinha', v.tipolinha, 'empresa', v.empresa, 'motorista', v.motorista, 'ocupacao', v.ocupacao,
             'aberta', v.chegada_ts is null) order by v.data_local desc, v.hora_saida desc), '[]'::jsonb) into x
      from (select * from viagens where normaliza_tag(frota) = f and data_local >= d - 6) v;
    r := r || jsonb_build_object('viagens', x,
      'lotacao', (select jsonb_build_object('viagens', count(*), 'com_leitura', count(*) filter (where ocupacao > 0),
                    'media', round(avg(ocupacao) filter (where ocupacao > 0), 1), 'maximo', max(ocupacao),
                    'lotadas', count(*) filter (where ocupacao > (cfg->>'lotacao_ideal')::int),
                    'super', count(*) filter (where ocupacao > (cfg->>'lugares')::int),
                    'empresa', mode() within group (order by empresa),
                    'motoristas', array_agg(distinct motorista) filter (where motorista is not null))
                  from viagens where normaliza_tag(frota) = f and data_local >= d - 6));
  exception when others then r := r || jsonb_build_object('viagens', jsonb_build_object('erro', sqlerrm)); end;
  end if;

  -- pontualidade e outros eventos (painel Eventos): últimos 14 dias
  if p_bloco is null or p_bloco = 'eventos' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'tipo', e.tipo, 'data', e.data, 'linha', e.linha, 'titulo', e.titulo,
             'situacao', e.situacao, 'justificativa', e.justificativa, 'motivo', e.motivo) order by e.data desc, e.id desc), '[]'::jsonb) into x
      from (select * from ev_eventos where normaliza_tag(frota) = f and data >= d - 13 order by data desc limit 30) e;
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('eventos', x);
  end if;

  -- aberturas erradas: últimos 7 dias
  if p_bloco is null or p_bloco = 'aberturas' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('regra', a.regra, 'gravidade', a.gravidade, 'data', a.data_local,
             'hora', to_char(a.hora, 'HH24:MI'), 'motorista', a.motorista, 'linha', a.linha, 'tipo', a.tipo, 'problema', a.problema,
             'situacao', coalesce(c.situacao, 'aberto')) order by a.data_local desc, a.hora desc), '[]'::jsonb) into x
      from abt_detectar(d - 6, d) a
      left join abt_casos c on c.viagem_id = a.viagem_id and c.regra = a.regra
     where normaliza_tag(a.frota) = f;
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('aberturas', x);
  end if;

  -- visitas da Caliman: últimos 60 dias + pendentes
  if p_bloco is null or p_bloco = 'visitas' then
  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'autor', v.autor, 'tipo', v.tipo, 'local', v.local, 'dia', v.dia,
             'hora_ini', to_char(v.hora_ini, 'HH24:MI'), 'hora_combinada', v.hora_combinada, 'status', v.status,
             'recado', v.recado, 'resposta', v.resposta) order by v.dia desc, v.id desc), '[]'::jsonb) into x
      from vis_propostas v
     where exists (select 1 from unnest(v.tags) t where normaliza_tag(t) = f)
       and (v.dia >= d - 60 or v.status = 'pendente');
  exception when others then x := jsonb_build_object('erro', sqlerrm); end;
  r := r || jsonb_build_object('visitas', x);
  end if;

  return r::json;
end $$;
grant execute on function public.onibus_ficha(text, text, text) to anon, authenticated;
