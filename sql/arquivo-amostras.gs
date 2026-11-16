/**
 * ARQUIVO DAS AMOSTRAS DO MONITOR NO GOOGLE DRIVE (complemento do robô do quadro de Demandas)
 *
 * Coloque este arquivo NO MESMO projeto do Apps Script do robô de Demandas
 * (ele usa a CHAVE, o SB_URL e a função rpc_ de lá):
 *   1. script.google.com → abra o projeto do robô de Demandas.
 *   2. Ao lado de "Arquivos", clique em + → Script → nome: arquivo-amostras → apague o que vier e cole este arquivo.
 *   3. Salve (Ctrl+S), escolha a função instalarArquivo em cima e clique em Executar.
 *      Vai pedir autorização nova (Google Drive): Revisar permissões → sua conta → Avançado → Acessar → Permitir.
 *
 * O que faz (a cada 15 minutos, até zerar a fila): pega no Supabase cada dia completo que ainda não foi
 * arquivado, monta um CSV com todas as leituras do dia, compacta (.csv.gz) e salva na pasta
 * "Monitor Frota - amostras" do seu Drive. Só depois de salvo ele marca o dia como arquivado;
 * a limpeza das 03:30 só apaga do Supabase os dias marcados.
 */

function arquivarAmostras() {
  const inicio = Date.now();
  const p = rpc_('arq_pendentes', { p_chave: CHAVE });
  if (!p || !p.dias || !p.dias.length) return;
  const pasta = pastaArquivo_(p.pasta || 'Monitor Frota - amostras');
  for (const dia of p.dias) {
    if (Date.now() - inicio > 4 * 60 * 1000) break;          // deixa o resto para a próxima rodada (limite de 6 min)
    const linhas = [];
    let depois = null, depoisId = 0, cab = null;
    while (true) {
      const r = rpc_('arq_pagina', { p_chave: CHAVE, p_dia: dia, p_depois: depois, p_depois_id: depoisId, p_limite: 3000 });
      const lote = (r && r.linhas) || [];
      if (!lote.length) break;
      if (!cab) cab = Object.keys(lote[0]);
      lote.forEach(o => linhas.push(cab.map(k => csv_(o[k])).join(',')));
      depois = r.ultimo_ts; depoisId = r.ultimo_id;
      if (lote.length < 3000) break;
      if (Date.now() - inicio > 5 * 60 * 1000) throw new Error('Tempo esgotado no dia ' + dia + '; tenta de novo na próxima rodada.');
    }
    if (!linhas.length) continue;
    const texto = cab.join(',') + '\n' + linhas.join('\n') + '\n';
    const nome = 'amostras-' + dia + '.csv';
    const gz = Utilities.gzip(Utilities.newBlob(texto, 'text/csv', nome), nome + '.gz');
    pasta.getFilesByName(nome + '.gz').hasNext() && apagarIguais_(pasta, nome + '.gz');
    const arq = pasta.createFile(gz);
    rpc_('arq_marcar', { p_chave: CHAVE, p_dia: dia, p_linhas: linhas.length, p_bytes: arq.getSize(),
                         p_arquivo_id: arq.getId(), p_link: arq.getUrl() });
    console.log('Arquivado ' + dia + ': ' + linhas.length + ' leituras, ' + Math.round(arq.getSize() / 1024) + ' KB');
  }
}

function csv_(v) {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function pastaArquivo_(nome) {
  const it = DriveApp.getFoldersByName(nome);
  return it.hasNext() ? it.next() : DriveApp.createFolder(nome);
}
function apagarIguais_(pasta, nome) {
  const it = pasta.getFilesByName(nome);
  while (it.hasNext()) it.next().setTrashed(true);
}

/** Execute UMA vez: cria o disparo a cada 15 minutos e já arquiva o que der. */
function instalarArquivo() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'arquivarAmostras')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('arquivarAmostras').timeBased().everyMinutes(15).create();
  arquivarAmostras();
  console.log('Arquivo das amostras instalado.');
}
