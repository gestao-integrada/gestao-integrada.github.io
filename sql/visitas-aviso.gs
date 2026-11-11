/**
 * VISITAS AOS CARROS — aviso por e-mail (complemento do robô do quadro de Demandas)
 *
 * Coloque este arquivo NO MESMO projeto do Apps Script do robô de Demandas
 * (ele usa a CHAVE, o SB_URL e a função rpc_ de lá):
 *   1. script.google.com → abra o projeto do robô de Demandas.
 *   2. Ao lado de "Arquivos", clique em + → Script → nome: visitas → apague o que vier e cole este arquivo.
 *   3. Salve (Ctrl+S), escolha a função instalarVisitas em cima e clique em Executar.
 *
 * O que faz (a cada 1 minuto):
 *   - pedido de visita, carro que mudou, aviso, recado ou cancelamento da Caliman → e-mail para você
 *     (a conta Google que roda o robô) com os botões ✅ Consigo ir / ❌ Não consigo (responde sem senha);
 *   - quando você confirma / recusa / manda recado → e-mail para a pessoa da Caliman,
 *     só se ela tiver e-mail cadastrado (é opcional).
 */

function avisarVisitas() {
  const r = rpc_('vis_avisos_pendentes', { p_chave: CHAVE });
  if (!r || !r.avisos || !r.avisos.length) return;
  const dono = Session.getEffectiveUser().getEmail();
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  r.avisos.forEach(a => {
    try {
      const para = a.para === 'dono' ? dono : a.email;
      if (!para) throw new Error('sem destinatário');
      const link = r.link + (a.proposta_id ? '?p=' + a.proposta_id : '');
      // botões de resposta rápida (só no seu e-mail, enquanto o pedido espera resposta)
      const bt = (txt, st, cor) => '<a href="' + esc(r.link + '?r=' + a.chave + '&s=' + st) + '" style="display:inline-block;background:' + cor +
        ';color:#fff;padding:12px 18px;border-radius:8px;text-decoration:none;font-weight:bold;margin:0 8px 8px 0">' + txt + '</a>';
      const botoes = a.para === 'dono' && a.chave && a.status === 'pendente'
        ? (a.tipo === 'visita' ? bt('✅ Consigo ir', 'confirmada', '#16a34a') + bt('❌ Não consigo', 'recusada', '#dc2626')
                               : bt('👍 Ciente', 'ciente', '#2563eb') + bt('✅ Vou passar lá', 'confirmada', '#16a34a'))
        : '';
      const html = '<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;max-width:560px">' +
        esc(a.texto).replace(/\n/g, '<br>') +
        (botoes ? '<p style="margin-top:18px">' + botoes + '</p>' : '') +
        '<p style="margin-top:' + (botoes ? '4' : '18') + 'px"><a href="' + esc(link) + '" style="display:inline-block;background:#16324f;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">' +
        (a.para === 'dono' ? 'Abrir a página' : 'Abrir a página de visitas') + '</a></p>' +
        '<div style="color:#888;font-size:12px">Aviso automático da página Visitas aos carros.<br>' + esc(link) + '</div></div>';
      MailApp.sendEmail({ to: para, subject: a.assunto, htmlBody: html, body: a.texto + '\n\nAbrir: ' + link });
      rpc_('vis_aviso_marcar', { p_chave: CHAVE, p_id: a.id, p_ok: true, p_erro: null });
    } catch (err) {
      rpc_('vis_aviso_marcar', { p_chave: CHAVE, p_id: a.id, p_ok: false, p_erro: String(err && err.message || err) });
    }
  });
}

/** Execute UMA vez: cria o disparo a cada 1 minuto e já testa. */
function instalarVisitas() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'avisarVisitas')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('avisarVisitas').timeBased().everyMinutes(1).create();
  avisarVisitas();
  console.log('Aviso de visitas instalado.');
}
