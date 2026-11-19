/**
 * BI — HORA DO MOTORISTA (planilha "CONTROLE DE OCUPAÇÃO E PONTUALIDADE", aba REGISTRO_VIAGENS → Supabase)
 *
 * Coloque este arquivo NO MESMO projeto do Apps Script do robô de Demandas
 * (ele usa a CHAVE, o SB_URL e a função rpc_ de lá):
 *   1. script.google.com → abra o projeto do robô de Demandas.
 *   2. Ao lado de "Arquivos", clique em + → Script → nome: forms-motorista → apague o que vier e cole este arquivo.
 *   3. Salve (Ctrl+S), escolha a função instalarFormsMotorista em cima e clique em Executar.
 *      O Google pede autorização nova (ler planilhas): Avançado → Acessar → Permitir.
 *
 * O que faz (a cada 15 minutos): manda para o Supabase as linhas novas da planilha
 * (e as últimas 300 de novo, para pegar correções). Lá cada linha é casada com a viagem da TFleet.
 * A conta Google que roda o robô precisa conseguir abrir a planilha.
 */

const FORMS_PLANILHA = '1NQ6fIyeJUsqZiIfVNoF8-sG32lQBEsIfGhfU3TKhpuE';
const FORMS_ABA = 'REGISTRO_VIAGENS';
const FORMS_LOTE = 300;

function enviarFormsMotorista() {
  const aba = SpreadsheetApp.openById(FORMS_PLANILHA).getSheetByName(FORMS_ABA);
  if (!aba) throw new Error('Aba ' + FORMS_ABA + ' não encontrada.');
  const ult = aba.getLastRow();
  if (ult < 2) return;
  // colunas pelo nome do cabeçalho (se mudarem de lugar continua funcionando)
  const cab = aba.getRange(1, 1, 1, aba.getLastColumn()).getDisplayValues()[0]
    .map(c => String(c).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim());
  const col = nome => cab.findIndex(c => c === nome || c.startsWith(nome));
  const C = {
    id: col('id'), data: col('data'), hora: col('hora'), motorista: col('motorista'), matricula: col('matricula'),
    veiculo: col('veiculo'), rota: col('rota'), operacao: col('operacao'), sentido: col('sentido'),
    passageiros: col('passageiros'), capacidade: col('capacidade'), ocupacao: col('ocupacao'),
    registro: cab.findIndex(c => c.startsWith('data/hora')), status: col('status'), uid: col('uid')
  };
  if (C.uid < 0 || C.data < 0 || C.hora < 0) throw new Error('Cabeçalho sem UID/Data/Hora.');
  const props = PropertiesService.getScriptProperties();
  const feito = Number(props.getProperty('forms_ate') || 1);
  let ini = Math.max(2, Math.min(feito, ult) - FORMS_LOTE + 1);
  if (feito <= 1) ini = 2;   // 1ª vez: manda tudo
  const t0 = Date.now();
  for (let a = ini; a <= ult; a += FORMS_LOTE) {
    if (Date.now() - t0 > 4.5 * 60 * 1000) break;   // o Apps Script para em 6 min: continua na próxima rodada
    const n = Math.min(FORMS_LOTE, ult - a + 1);
    const L = aba.getRange(a, 1, n, aba.getLastColumn()).getDisplayValues();
    const linhas = L.filter(r => r[C.uid]).map(r => {
      const o = {};
      Object.keys(C).forEach(k => { if (C[k] >= 0) o[k] = r[C[k]]; });
      return o;
    });
    if (linhas.length) {
      const res = rpc_('bi_forms_receber', { p_chave: CHAVE, p_linhas: linhas });
      console.log('Linhas ' + a + '–' + (a + n - 1) + ': ' + JSON.stringify(res));
    }
    props.setProperty('forms_ate', String(a + n - 1));
  }
}

/** Execute UMA vez: cria o disparo a cada 15 minutos e já manda a planilha inteira. */
function instalarFormsMotorista() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'enviarFormsMotorista')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('enviarFormsMotorista').timeBased().everyMinutes(15).create();
  PropertiesService.getScriptProperties().deleteProperty('forms_ate');
  enviarFormsMotorista();
  console.log('Robô do Forms dos motoristas instalado.');
}
