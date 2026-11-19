-- =====================================================================
-- ALERTAS COM MENOS RUÍDO — regra padrão para todo aviso automático (19/11)
--   1) tempo/quantidade mínima antes de avisar
--   2) não reabrir o que você já descartou/marcou como falso
--   3) resumo 1x por dia em vez de mensagens soltas
--
-- Rodar inteiro no Supabase → SQL Editor → New query → Run. Pode rodar de novo.
-- Não apaga dados. Os números ficam na tabela alerta_regras (Table Editor) e podem
-- ser mudados ali, sem mexer em código.
-- =====================================================================

-- ---------------------------------------------------------------- 0) tabela única com as regras
create table if not exists public.alerta_regras (
  codigo           text primary key,
  nome             text not null,
  onde             text,
  min_minutos      int,       -- tempo mínimo antes de virar alerta
  min_mb           numeric,   -- roteador: consumo mínimo
  nao_reabrir_dias int,       -- depois de descartado/falso, não abre igual por X dias
  lembrete_dias    int,       -- de quantos em quantos dias repete o lembrete
  max_dias         int,       -- para de lembrar depois de X dias
  envio            text,      -- 'diario' ou 'na_hora' (informativo; o envio real segue o painel Eventos)
  obs              text,
  atualizado_em    timestamptz not null default now()
);
alter table public.alerta_regras enable row level security;
revoke all on public.alerta_regras from anon, authenticated;

insert into public.alerta_regras (codigo, nome, onde, min_minutos, min_mb, nao_reabrir_dias, lembrete_dias, max_dias, envio, obs) values
  ('carga_lenta', 'Carregador (ocorrência automática)', 'abrir_ocorrencias_carga_lenta (cron 30 min)', 30, null, 7, null, null, 'diario',
   'Já aplicado em carga-lenta-menos-alertas.sql: 30 min andando na tomada, corrente fraca, bateria sem subir.'),
  ('roteador', 'Uso de roteador', 'n8n resumo diário + painel Eventos', null, 5, null, null, null, 'diario',
   'Consumo mínimo: o resumo do n8n usa o "MB mínimo" da aba Uso no roteador do Monitor. Deixe igual a min_mb.'),
  ('fora_rota_whats', 'Passageiro fora de rota (WhatsApp ao gestor)', 'whatsapp_fora_rota (n8n)', null, null, null, 3, 10, 'diario',
   'Antes: todo dia por 14 dias. Agora: 1º aviso e lembrete a cada 3 dias, até 10 dias (no máximo 4 mensagens).'),
  ('abertura', 'Abertura errada de viagem', 'abt_rodar (cron 1h, aviso 1x/dia)', null, null, 7, null, null, 'diario',
   'Caso igual (carro + rota + sentido + regra) a um marcado como FALSO nos últimos 7 dias entra já como falso e não é avisado.'),
  ('pontualidade', 'Pontualidade nas cercas', 'painel Eventos', null, null, null, null, null, 'diario',
   'Tempo mínimo = tolerância da cerca (BI). Resumo diário às 8h.')
on conflict (codigo) do nothing;

-- ---------------------------------------------------------------- 1) painel Eventos: tudo em resumo diário
-- O roteador estava "na hora" (1 mensagem a cada rodada de 15 min). Passa para o resumo das 8h.
-- Se quiser voltar algum tipo, é só mudar no painel Eventos.
update public.ev_tipos set envio = 'diario', hora_envio = 8 where envio = 'na_hora';

-- ---------------------------------------------------------------- 2) fora de rota: lembrete a cada 3 dias (não todo dia)
create or replace function public.whatsapp_fora_rota(p_teste_numero text default null,
                                                     p_resposta_url text default 'https://zael20.github.io/painel-mes-tfleet-bdv/resposta.html',
                                                     p_dias integer default 14)
returns table (token uuid, telefone text, gestor text, pessoas integer, texto text)
language plpgsql volatile security definer set search_path = public as $$
declare r record; v_tok uuid; v_fone text := norm_fone(p_teste_numero);
  v_cada int; v_max int; hoje date := (now() at time zone 'America/Belem')::date;
begin
  select coalesce(lembrete_dias, 3), coalesce(max_dias, 10) into v_cada, v_max from alerta_regras where codigo = 'fora_rota_whats';
  v_cada := greatest(coalesce(v_cada, 3), 1); v_max := greatest(coalesce(v_max, 10), 1);
  if nullif(trim(p_teste_numero), '') is not null then
    if v_fone is null then raise exception 'numero de teste invalido (use DDD + numero): %', p_teste_numero; end if;
    insert into consultas_lotes (telefone, gestor_nome, consulta_ids, teste)
    select v_fone, null, array_agg(x.id), true
    from (select c.id from consultas c where c.resposta is null and c.criado_em > now() - interval '14 days'
          order by c.criado_em desc, c.id limit 5) x
    having count(*) > 0
    returning consultas_lotes.token into v_tok;
    if v_tok is null then raise exception 'nenhuma consulta sem resposta nos ultimos 14 dias para testar'; end if;
    return query select l.token, l.telefone, 'teste'::text, cardinality(l.consulta_ids),
                        whatsapp_texto_lote(l.consulta_ids, null, p_resposta_url || '?l=' || l.token, true)
                 from consultas_lotes l where l.token = v_tok;
    return;
  end if;
  for r in
    with c as (
      select c.id, g.telefones, g.nome as gnome
      from consultas c
      left join lateral ultimo_embarque_pessoa(c.matricula, c.nome) u on true
      left join lateral gestor_de(c.matricula, c.nome, coalesce(c.ga, u.ga), coalesce(c.gg, u.gg), u.centrocusto, u.empresa) g on true
      where c.enviado_para is not null and c.resposta is null
        and (c.whatsapp_em is null or hoje - (c.whatsapp_em at time zone 'America/Belem')::date >= v_cada)
        and c.criado_em > now() - make_interval(days => v_max)
    )
    select f.fone, (select x.nome from (select e.nome from gestores_empresa_contatos e where e.telefone = f.fone and e.nome is not null
                                        union all select b.nome from gestores_base b where b.telefone = f.fone and b.nome is not null) x limit 1) as gnome,
           array_agg(distinct c.id) as ids
    from c cross join lateral unnest(string_to_array(c.telefones, ',')) f(fone)
    where nullif(f.fone, '') is not null
    group by f.fone
  loop
    insert into consultas_lotes (telefone, gestor_nome, consulta_ids) values (r.fone, r.gnome, r.ids) returning consultas_lotes.token into v_tok;
    return query select v_tok, r.fone, r.gnome, cardinality(r.ids),
                        whatsapp_texto_lote(r.ids, r.gnome, p_resposta_url || '?l=' || v_tok, false);
  end loop;
end $$;
revoke execute on function public.whatsapp_fora_rota(text, text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3) aberturas: não reabrir o que foi marcado como falso
create or replace function public.abt_nao_reabrir() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_dias int; x record;
begin
  if new.situacao <> 'aberto' then return new; end if;
  select coalesce(nao_reabrir_dias, 7) into v_dias from alerta_regras where codigo = 'abertura';
  if coalesce(v_dias, 7) <= 0 then return new; end if;
  select a.data_local, a.marcado_por into x from abt_casos a
   where a.situacao = 'falso' and a.regra = new.regra
     and a.frota is not distinct from new.frota and a.linha is not distinct from new.linha and a.tipo is not distinct from new.tipo
     and coalesce(a.marcado_em, a.detectado_em) > now() - make_interval(days => coalesce(v_dias, 7))
   order by a.marcado_em desc nulls last limit 1;
  if found then
    new.situacao := 'falso';
    new.marcado_por := 'Robô (regra de alertas)';
    new.marcado_em := now();
    new.obs := 'Automático: igual ao caso de ' || to_char(x.data_local, 'DD/MM') || ' marcado como falso' ||
               coalesce(' por ' || x.marcado_por, '') || '. Não foi avisado. Se estiver errado, mude a situação.';
  end if;
  return new;
end $$;
drop trigger if exists abt_nao_reabrir on public.abt_casos;
create trigger abt_nao_reabrir before insert on public.abt_casos for each row execute function public.abt_nao_reabrir();

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------- conferência
select codigo, nome, min_minutos, min_mb, nao_reabrir_dias, lembrete_dias, max_dias, envio from public.alerta_regras order by codigo;
