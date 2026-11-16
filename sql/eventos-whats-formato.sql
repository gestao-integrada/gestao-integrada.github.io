-- WhatsApp dos eventos mais legível: agrupa por dia, carro em negrito, ida/volta e previsto em linhas separadas.
-- Só muda o TEXTO do WhatsApp (o e-mail continua igual). Pode rodar de novo sem problema.
create or replace function public._ev_whats_texto(p_envio bigint) returns text
language plpgsql stable security definer set search_path = public as $$
declare v ev_envios; t ev_tipos; r record; txt text; dia_ant date; qtd int; prazo timestamptz;
  dias text[] := array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'];
begin
  select * into v from ev_envios where id = p_envio;
  select * into t from ev_tipos where codigo = v.tipo;
  select count(*), min(e.prazo) into qtd, prazo from ev_envio_itens x join ev_eventos e on e.id = x.evento_id where x.envio_id = v.id;
  if v.tipo <> 'pontualidade' or qtd = 0 then
    return '🚌 *' || v.assunto || '*' || chr(10) || chr(10) || v.texto;
  end if;
  txt := '🚌 *' || t.nome || '*' || chr(10) ||
         'Olá, ' || initcap(split_part(coalesce(v.nome, ''), ' ', 1)) || '!' || chr(10) || chr(10) ||
         '*' || qtd || (case when qtd = 1 then ' viagem' else ' viagens' end) || '* fora do horário ' ||
         (case when qtd = 1 then 'precisa' else 'precisam' end) || ' de justificativa' ||
         (case when t.exige_evidencia then ' com evidência (foto, print ou documento)' else '' end) || '.' || chr(10) ||
         '⏰ Prazo: *' || to_char(coalesce(prazo, v.criado_em + make_interval(hours => t.prazo_horas)) at time zone 'America/Belem', 'DD/MM "às" HH24:MI') || '*';
  for r in select e.*, x.rodada as rod from ev_envio_itens x join ev_eventos e on e.id = x.evento_id
            where x.envio_id = v.id order by e.data, e.ocorreu_em, e.frota limit 15 loop
    if dia_ant is distinct from r.data then
      txt := txt || chr(10) || chr(10) || '📅 *' || dias[extract(dow from r.data)::int + 1] || ', ' || to_char(r.data, 'DD/MM') || '*';
      dia_ant := r.data;
    end if;
    txt := txt || chr(10) || chr(10) ||
      (case when r.detalhe->>'status' = 'atrasado' then '🔴' else '🟡' end) || ' *Carro ' || coalesce(r.frota, '?') || '* · ' ||
      trim(regexp_replace(regexp_replace(coalesce(r.linha, ''), '\s*\((IDA|VOLTA)\)\s*$', '', 'i'), '\s+', ' ', 'g')) || chr(10) ||
      (case when r.detalhe->>'tipo' = 'VOLTA' then '      Volta: saiu ' else '      Ida: chegou ' end) ||
      '*' || coalesce(r.detalhe->>'hora_real', '?') || '* (previsto ' || coalesce(r.detalhe->>'prevista', '?') || ')' || chr(10) ||
      '      *' || abs(coalesce((r.detalhe->>'dif')::int, 0)) || ' min ' || coalesce(r.detalhe->>'status', '') || '*' ||
      (case when r.situacao = 'refazer' then chr(10) || '      ↩️ Devolvido: ' || coalesce(r.analise_obs, 'refazer') else '' end);
  end loop;
  if qtd > 15 then txt := txt || chr(10) || chr(10) || '… e mais ' || (qtd - 15) || ' no link.'; end if;
  return txt;
end $$;
revoke all on function public._ev_whats_texto(bigint) from public, anon, authenticated;

create or replace function public.ev_whats_pendentes(p_limite integer default 5) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('avisos', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'numero', v.destino,
      'texto', public._ev_whats_texto(v.id) || chr(10) || chr(10) ||
               case when v.link is null then '👉 *Justificar e anexar a evidência:*' || chr(10) || (select link from ev_config where id = 1) || '?t=' || v.token
                    else '👉 *Abrir:*' || chr(10) || v.link end) order by v.id)
    from (select * from ev_envios where canal = 'whatsapp' and enviado_em is null and tentativas < 3 and expira_em > now()
            and criado_em > now() - interval '12 hours'
          order by id limit greatest(1, least(coalesce(p_limite, 5), 20))) v), '[]'::jsonb));
end $$;
revoke all on function public.ev_whats_pendentes(integer) from public, anon, authenticated;
grant execute on function public.ev_whats_pendentes(integer) to service_role;

-- prévia: como fica o último aviso de WhatsApp de pontualidade
select public._ev_whats_texto(id) as previa from public.ev_envios
where canal = 'whatsapp' and tipo = 'pontualidade' order by id desc limit 1;
