/**
 * EVENTOS — envio por e-mail (complemento do robô do quadro de Demandas)
 *
 * Coloque este arquivo NO MESMO projeto do Apps Script do robô de Demandas
 * (ele usa a CHAVE, o SB_URL e a função rpc_ de lá):
 *   1. script.google.com → abra o projeto do robô de Demandas.
 *   2. Ao lado de "Arquivos", clique em + → Script → nome: eventos → apague o que vier e cole este arquivo.
 *   3. Salve (Ctrl+S), escolha a função instalarEventos em cima e clique em Executar.
 *
 * O que faz (a cada 5 minutos): pega na fila do painel Eventos os e-mails a mandar
 * (quem está marcado com ✉ em "Quem recebe o quê") e manda com o botão "Justificar e anexar evidência".
 */

function avisarEventos() {
  const r = rpc_('ev_emails_pendentes', { p_chave: CHAVE });
  if (!r || !r.envios || !r.envios.length) return;
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  r.envios.forEach(e => {
    try {
      const html = '<div style="font-family:Arial,sans-serif;font-size:15px;line-height:1.5;max-width:600px">' +
        esc(e.texto).replace(/\n/g, '<br>') +
        '<p style="margin-top:18px"><a href="' + esc(e.link) + '" style="display:inline-block;background:#2563eb;color:#fff;padding:12px 18px;' +
        'border-radius:8px;text-decoration:none;font-weight:bold">Justificar e anexar evidência</a></p>' +
        '<div style="color:#888;font-size:12px">Aviso automático do painel Eventos da frota. O link vale só para você; não encaminhe.<br>' + esc(e.link) + '</div></div>';
      MailApp.sendEmail({ to: e.para, subject: e.assunto, htmlBody: html, body: e.texto + '\n\nJustificar: ' + e.link });
      rpc_('ev_email_marcar', { p_chave: CHAVE, p_id: e.id, p_ok: true, p_erro: null });
    } catch (err) {
      rpc_('ev_email_marcar', { p_chave: CHAVE, p_id: e.id, p_ok: false, p_erro: String(err && err.message || err) });
    }
  });
}

/** Execute UMA vez: cria o disparo a cada 5 minutos e já testa. */
function instalarEventos() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'avisarEventos')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('avisarEventos').timeBased().everyMinutes(5).create();
  avisarEventos();
  console.log('Envio de eventos instalado.');
}
