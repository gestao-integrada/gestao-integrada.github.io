/* Visitas aos carros — viagens abertas erradas no app (dados da TFleet, sql/aberturas.sql)
   - aba "Viagens abertas erradas" no topo (análise por período, igual ao painel /aberturas/)
   - seção "Viagens abertas erradas ontem" na aba principal, entre os carros e as idas (window.htmlAberturas)
   Usa rpc, $, esc, TOKEN, D e EQ() da página. */
(function(){
const REGRA={"1 SENTIDO":"Sentido","2 ROTA ESPECIAL":"Rota especial","3 REPETIDA":"Repetida","4 ROTA DUPLICADA":"Rota duplicada","5 DUAS ROTAS":"Duas rotas","6 DOIS CARROS":"Dois carros"};
const GRAV={alta:0,media:1,verificar:2};
const hojeL=()=>new Date(Date.now()-3*3600e3).toISOString().slice(0,10);
const menos=(d,n)=>new Date(Date.parse(d+"T12:00:00Z")-n*864e5).toISOString().slice(0,10);
const dm=s=>s?String(s).slice(8,10)+"/"+String(s).slice(5,7):"";
const dBR=s=>s?String(s).slice(0,10).split("-").reverse().join("/"):"—";
const dtBR=s=>{if(!s)return"";const d=new Date(s);return d.toLocaleDateString("pt-BR",{day:"2-digit",month:"2-digit"})+" "+d.toLocaleTimeString("pt-BR",{hour:"2-digit",minute:"2-digit"})};
const nome=n=>String(n||"?").toLowerCase().replace(/(^|\s)\S/g,c=>c.toUpperCase());
const grupoDe=c=>/^CT\d/i.test(c.linha)?"CT":/^TURNO/i.test(c.tipolinha)?"TURNO":"ADM";
const msgErro=e=>/does not exist|Could not find|não tem a parte|não instalada/i.test(e.message)?"Falta rodar o aberturas.sql no Supabase.":e.message;

/* ---------- estilo (prefixo ab- para não mexer no resto da página) ---------- */
document.head.insertAdjacentHTML("beforeend",`<style>
.ab-tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin:4px 0 10px}
.ab-tabs button{background:none;border:0;border-bottom:3px solid transparent;color:var(--mut);padding:8px 12px;font:600 14px system-ui,sans-serif;flex:0 1 auto;line-height:1.3}
@media (max-width:520px){.ab-tabs button{flex:1 1 0;padding:8px 6px;font-size:13px}}
#abaAbt a.btn{text-decoration:none}
.ab-tabs button.on{color:var(--ink);border-bottom-color:var(--brand)}
.ab-tabs .ab-n{background:var(--redbg);color:var(--red);border-radius:999px;padding:0 7px;font-size:12px;margin-left:4px}
body.ab-aba #fxPend,body.ab-aba #fxDisp,body.ab-aba #blocos,body.ab-aba #atual,body.ab-aba #fab,body.ab-aba #selbar{display:none!important}
body:not(.ab-aba) #abaAbt{display:none}
.ab-bul{list-style:none;margin:0 0 14px;padding:0;display:flex;flex-direction:column;gap:6px}
.ab-bul li{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--ora);border-radius:8px;padding:5px 10px;font-size:13px;cursor:pointer}
.ab-bul li.alta{border-left-color:var(--red)}.ab-bul li.verificar{border-left-color:var(--gry)}
.ab-bul li:hover{border-color:var(--brand)}
.ab-chip{display:inline-block;font-size:11px;font-weight:700;border-radius:999px;padding:1px 8px;white-space:nowrap}
.ab-alta{background:var(--redbg);color:var(--red)}.ab-media{background:var(--orabg);color:var(--ora)}.ab-verificar{background:var(--grybg);color:var(--gry)}
.ab-ok{background:var(--grnbg);color:var(--grn)}.ab-blu{background:var(--blubg);color:var(--blu)}
.ab-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:4px 0 8px}
.ab-bar input,.ab-bar select{border:1px solid var(--line);background:var(--card2);color:var(--ink);border-radius:8px;padding:7px 10px;min-width:0}
.ab-bar input[type=search]{flex:1 1 180px;max-width:300px}
.ab-fx{border-radius:10px;padding:9px 12px;margin:8px 0;font-size:14px;border:1px solid var(--line);background:var(--card);display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center}
.ab-fx.warn{background:var(--orabg);color:var(--ora);font-weight:600}
.ab-fx .r{margin-left:auto;display:flex;gap:6px;flex-wrap:wrap}
.ab-kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:8px;margin:10px 0}
.ab-kpi{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:9px 12px;text-align:left;color:var(--ink)}
.ab-kpi.on{outline:2px solid var(--brand);outline-offset:-1px}
.ab-kpi b{display:block;font-size:22px;line-height:1.1}.ab-kpi span,.ab-kpi small{font-size:12px;color:var(--mut)}.ab-kpi small{display:block}
.ab-cols{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:8px 0}
@media (max-width:760px){.ab-cols{grid-template-columns:1fr}}
.ab-box{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px;min-width:0}
.ab-box h3{font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--mut);margin:0 0 6px}
.ab-rk{width:100%;border-collapse:collapse;font-size:13px}
.ab-rk td{padding:4px;border-top:1px solid var(--line)}.ab-rk tr{cursor:pointer}.ab-rk tr.on td{background:var(--blubg)}
.ab-rk td.n{text-align:right;font-weight:700;width:40px}
.ab-rk .barra{height:5px;background:var(--grybg);border-radius:3px;margin-top:2px}.ab-rk .barra i{display:block;height:5px;background:var(--brand);border-radius:3px}
.ab-casos{display:flex;flex-direction:column;gap:8px}
.ab-caso{background:var(--card);border:1px solid var(--line);border-left:5px solid var(--ora);border-radius:12px;padding:10px 12px;min-width:0}
.ab-caso.alta{border-left-color:var(--red)}.ab-caso.verificar{border-left-color:var(--gry)}.ab-caso.ok{opacity:.6;border-left-color:var(--grn)}
.ab-caso .l1{display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline}
.ab-caso ul{margin:6px 0 0;padding:0;list-style:none;font-size:14px}
.ab-caso li{padding:4px 0;border-top:1px dashed var(--line)}
.ab-caso .sg{color:var(--mut);font-size:13px;display:block}
.ab-caso .acts{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;align-items:center}
.ab-caso .acts .info{font-size:12px;color:var(--mut);margin-right:auto}
.ab-regras{font-size:13px;color:var(--mut);margin:6px 0 0;padding-left:18px}
</style>`);

/* ---------- abas ---------- */
const app=document.getElementById("vApp"), header=app.querySelector("header.top");
header.insertAdjacentHTML("afterend",'<nav class="ab-tabs" id="abTabs"><button data-aba="agenda" class="on">Agenda e ocorrências</button>'+
  '<button data-aba="abt">Viagens abertas erradas<span class="ab-n hidden" id="abN"></span></button></nav>');
app.insertAdjacentHTML("beforeend",'<div id="abaAbt"></div>');
function aba(qual){
  document.body.classList.toggle("ab-aba",qual==="abt");
  document.querySelectorAll("#abTabs button").forEach(b=>b.classList.toggle("on",b.dataset.aba===qual));
  try{history.replaceState(null,"",qual==="abt"?"#aberturas":location.pathname+location.search)}catch(e){}
  if(qual==="abt"){if(!A.dados)carregarAba();else desenharAba()}
  window.scrollTo(0,0);
}
document.getElementById("abTabs").onclick=e=>{const b=e.target.closest("button");if(b)aba(b.dataset.aba)};

/* ---------- estado ---------- */
const A={ontem:null,ontemEm:0,carregando:false,dados:null,de:null,ate:null,filtro:{regra:null,mot:null,rota:null}};

/* ---------- seção da aba principal: ontem (D-1) ---------- */
async function carregarOntem(){
  if(A.carregando||!TOKEN)return;A.carregando=true;
  const dia=menos(hojeL(),1);
  try{A.ontem=await rpc("abt_visitas",{p_token:TOKEN,p_de:dia,p_ate:dia});A.erro=null}
  catch(e){A.erro=msgErro(e);A.ontem=null}
  A.ontemEm=Date.now();A.carregando=false;
  const n=A.ontem?viagens(A.ontem).filter(v=>v.sit==="aberto").length:0;
  const bn=document.getElementById("abN");bn.textContent=n;bn.classList.toggle("hidden",!n);
  if(typeof D!=="undefined"&&D&&!document.body.classList.contains("ab-aba"))desenhar();
}
window.htmlAberturas=function(){
  if(!TOKEN)return "";
  if(Date.now()-A.ontemEm>10*60e3)setTimeout(carregarOntem,0);
  if(A.erro)return EQ()?'<div class="note" style="margin:4px 0 12px">🚌 Viagens abertas erradas: '+esc(A.erro)+'</div>':"";
  if(!A.ontem)return "";
  const dia=menos(hojeL(),1);
  const L=viagens(A.ontem).filter(v=>v.sit==="aberto").sort((a,b)=>a.hora.localeCompare(b.hora));
  let h='<h2 class="sec" style="font-size:13px">Viagens abertas erradas ontem ('+dm(dia)+') <span class="n">'+L.length+'</span>'+
    '<span class="r"><button class="btn sm" id="abVer">Ver análise →</button></span></h2>';
  if(!A.ontem.viagens)return h+'<div class="note" style="margin:-4px 0 14px">A TFleet ainda não mandou as viagens de ontem.</div>';
  if(!L.length)return h+'<div class="note" style="margin:-4px 0 14px">✓ Nenhuma viagem aberta errada ontem ('+A.ontem.viagens+' viagens conferidas).</div>';
  h+='<div class="note" style="margin:-4px 0 6px">Motoristas que abriram a viagem com sentido, rota ou horário errado no app. Oriente para abrir certo hoje. Toque para ver o detalhe.</div><ul class="ab-bul">';
  for(const v of L){
    const r=v.regras[0];
    h+='<li class="'+v.grav+'" data-abv="'+esc(v.viagem_id)+'"><b>carro '+esc(v.frota)+' · '+esc(nome(v.motorista))+'</b> · '+esc(v.linha)+' '+esc(v.tipo)+' às '+esc(v.hora)+' '+
      v.regras.map(x=>'<span class="ab-chip ab-'+x.gravidade+'">'+esc(REGRA[x.regra]||x.regra)+'</span>').join(" ")+
      '<div class="note">→ '+esc(r.sugestao)+'</div></li>';
  }
  return h+'</ul>';
};
// cliques da seção (o #blocos é redesenhado, então o clique fica no documento)
document.addEventListener("click",e=>{
  if(e.target.closest("#abVer")){const d=menos(hojeL(),1);A.de=d;A.ate=d;A.dados=null;aba("abt");return}
  const li=e.target.closest("[data-abv]");
  if(li){const d=menos(hojeL(),1);A.de=d;A.ate=d;A.dados=null;A.foco=li.dataset.abv;aba("abt")}
});

/* ---------- juntar as regras da mesma viagem ---------- */
function viagens(dados){
  const m=new Map();
  for(const c of dados.casos||[]){
    let v=m.get(c.viagem_id);
    if(!v){v={...c,regras:[],grav:c.gravidade};m.set(c.viagem_id,v)}
    v.regras.push(c);if(GRAV[c.gravidade]<GRAV[v.grav])v.grav=c.gravidade;
  }
  for(const v of m.values()){
    const s=v.regras.map(r=>r.situacao);
    v.sit=s.every(x=>x==="falso")?"falso":s.every(x=>x!=="aberto")?"corrigido":"aberto";
    v.avisado=v.regras.find(r=>r.avisado_em)||null;
  }
  return [...m.values()];
}

/* ---------- aba de análise ---------- */
async function carregarAba(){
  const box=document.getElementById("abaAbt");
  if(!A.de){A.ate=menos(hojeL(),1);A.de=menos(A.ate,6)}
  if(!document.getElementById("abLista"))montarAba();
  document.getElementById("abLista").innerHTML='<div class="vazio">Carregando…</div>';
  try{A.dados=await rpc("abt_visitas",{p_token:TOKEN,p_de:A.de,p_ate:A.ate});desenharAba()}
  catch(e){document.getElementById("abLista").innerHTML='<div class="vazio">'+esc(msgErro(e))+'</div>'}
}
function montarAba(){
  const eq=EQ();
  document.getElementById("abaAbt").innerHTML=
    '<div class="note" style="margin:0 0 6px">Viagens que o motorista abriu com sentido, rota ou horário errado no app (dados da TFleet, que chegam com 1 dia de atraso).</div>'+
    '<div class="ab-bar"><label class="note">De <input type="date" id="abDe"></label><label class="note">até <input type="date" id="abAte"></label>'+
    '<input type="search" id="abBusca" placeholder="Buscar motorista, carro ou rota">'+
    '<select id="abGrupo"><option value="">Todos os grupos</option><option value="ADM">ADM</option><option value="CT">CT (terceiros)</option><option value="TURNO">Turno</option></select>'+
    '<select id="abSit"><option value="aberto">Em aberto</option><option value="">Todas</option><option value="corrigido">Corrigidas</option>'+(eq?'<option value="falso">Estavam certas</option>':'')+'</select>'+
    '<button class="btn sm" id="abCsv">⬇ Planilha</button></div>'+
    '<div id="abFx"></div><div class="ab-kpis" id="abKpis"></div>'+
    '<div class="ab-cols"><div class="ab-box"><h3>Motoristas com mais erros</h3><table class="ab-rk" id="abRkMot"></table></div>'+
    '<div class="ab-box"><h3>Rotas com mais erros</h3><table class="ab-rk" id="abRkRota"></table></div></div>'+
    '<h2 class="sec">Viagens <span class="n" id="abNc">0</span><span id="abFt" class="note"></span></h2><div class="ab-casos" id="abLista"></div>'+
    '<details class="ab-box" style="margin-top:18px"><summary style="cursor:pointer;font-weight:600">Como a página decide que a abertura está errada</summary><ol class="ab-regras">'+
    '<li><b>Sentido</b>: no ADM, IDA aberta depois das 11h (era VOLTA) ou VOLTA antes das 10h (era IDA). Aprendiz, Extra e In Haus ficam fora. No turno, horário do outro sentido.</li>'+
    '<li><b>Rota especial</b>: rota que em certo horário tem outro nome (CT7 entre 06:30 e 08:30 = CT7 INTERNO).</li>'+
    '<li><b>Repetida</b>: o mesmo carro abriu a mesma rota e sentido 2 vezes no dia.</li>'+
    '<li><b>Rota duplicada</b>: 2 carros na mesma rota e sentido no mesmo período; marca o carro que menos costuma fazer essa rota e diz a rota provável.</li>'+
    '<li><b>Duas rotas</b>: o mesmo carro abriu 2 rotas diferentes no mesmo sentido em menos de 1 h.</li>'+
    '<li><b>Dois carros</b>: o mesmo motorista em 2 carros ao mesmo tempo (provável login de outro motorista).</li></ol></details>';
  const $$=id=>document.getElementById(id);
  $$("abDe").value=A.de;$$("abAte").value=A.ate;
  $$("abDe").onchange=()=>{A.de=$$("abDe").value;carregarAba()};$$("abAte").onchange=()=>{A.ate=$$("abAte").value;carregarAba()};
  ["abBusca","abGrupo","abSit"].forEach(i=>$$(i).addEventListener("input",desenharAba));
  $$("abCsv").onclick=planilha;
}
function filtrar(lista,ign){
  const g=id=>document.getElementById(id).value;
  const q=g("abBusca").trim().toLowerCase(),gr=g("abGrupo"),s=g("abSit"),F=A.filtro;
  return lista.filter(v=>(!q||(v.motorista+" "+v.frota+" "+v.linha).toLowerCase().includes(q))&&(!gr||grupoDe(v)===gr)&&(!s||v.sit===s)
    &&(ign==="regra"||!F.regra||v.regras.some(r=>r.regra===F.regra))&&(ign==="mot"||!F.mot||v.motorista===F.mot)&&(ign==="rota"||!F.rota||v.linha===F.rota));
}
function desenharAba(){
  if(!A.dados)return;
  if(!document.getElementById("abLista"))montarAba();
  const $$=id=>document.getElementById(id), X=A.dados, eq=EQ(), cf=X.config||{}, d=X.demanda;
  $$("abDe").value=A.de;$$("abAte").value=A.ate;
  // faixas: coleta e demanda
  const col=X.coleta?new Date(X.coleta):null, atraso=col?(Date.now()-col)/36e5:99;
  let fx=atraso>=2?'<div class="ab-fx warn">⚠ A coleta da TFleet não acontece desde '+(col?dtBR(X.coleta):"—")+': viagens depois disso ainda não entram.</div>':'';
  fx+='<div class="ab-fx">'+(d?'<span>📋 Demanda da '+esc(cf.fornecedor||"Caliman")+' <b>#'+d.id+'</b> <span class="ab-chip ab-blu">'+esc(d.status)+'</span></span>'+
      '<span>Responsável: <b>'+esc(d.responsavel||"—")+'</b></span><span>Prazo: <b>'+dBR(d.prazo)+'</b></span>':'<span>Ainda não foi aberta demanda para a Caliman.</span>')+
    '<span class="note">'+(cf.ativo?'Casos novos vão sozinhos para a demanda todo dia às '+cf.hora_aviso+'h':'Envio automático desligado')+'</span>'+
    '<span class="r">'+(d?'<a class="btn sm" target="_blank" rel="noopener" href="'+esc(d.link)+'">Abrir demanda</a>':'')+
    (eq?'<button class="btn sm p" id="abAgora">Mandar agora para a Caliman</button><a class="btn sm" href="../aberturas/" target="_blank" rel="noopener">⚙ Ajustes</a>':'')+'</span></div>';
  fx+='<div class="note" style="margin:0 0 6px">'+(X.rotas_vigiadas?'Só as <b>'+X.rotas_vigiadas+' rotas vigiadas</b> (as mesmas das idas que não subiram'+(eq?'; muda em "Rotas vigiadas"':'')+').':'Nenhuma rota vigiada escolhida: mostrando todas as rotas.')+'</div>';
  $$("abFx").innerHTML=fx;
  if($$("abAgora"))$$("abAgora").onclick=async()=>{if(!confirm("Mandar agora os casos de dias anteriores que ainda não foram avisados?"))return;
    try{alert(await rpc("abt_enviar_agora",{p_token:TOKEN}));carregarAba()}catch(e){alert(msgErro(e))}};
  const todas=viagens(X);
  // indicadores
  const baseK=filtrar(todas,"regra"),cont={};
  baseK.forEach(v=>new Set(v.regras.map(r=>r.regra)).forEach(r=>cont[r]=(cont[r]||0)+1));
  const pct=X.viagens?Math.round(1000*baseK.length/X.viagens)/10:0;
  $$("abKpis").innerHTML='<button class="ab-kpi'+(!A.filtro.regra?" on":"")+'" data-r=""><b>'+baseK.length+'</b><span>viagens com erro</span><small>'+pct+'% de '+X.viagens+' viagens</small></button>'+
    Object.keys(REGRA).map(r=>'<button class="ab-kpi'+(A.filtro.regra===r?" on":"")+'" data-r="'+r+'"><b>'+(cont[r]||0)+'</b><span>'+REGRA[r]+'</span></button>').join("");
  $$("abKpis").querySelectorAll(".ab-kpi").forEach(b=>b.onclick=()=>{A.filtro.regra=b.dataset.r||null;desenharAba()});
  rank("abRkMot",filtrar(todas,"mot"),v=>v.motorista,"mot",nome);
  rank("abRkRota",filtrar(todas,"rota"),v=>v.linha,"rota",x=>x);
  // lista
  const lista=filtrar(todas).sort((a,b)=>(b.data+b.hora).localeCompare(a.data+a.hora));
  $$("abNc").textContent=lista.length;
  const f=[A.filtro.regra&&REGRA[A.filtro.regra],A.filtro.mot&&nome(A.filtro.mot),A.filtro.rota].filter(Boolean);
  $$("abFt").innerHTML=f.length?'filtro: '+esc(f.join(" · "))+' <button class="btn sm" id="abLimpa">limpar</button>':"";
  if($$("abLimpa"))$$("abLimpa").onclick=()=>{A.filtro={regra:null,mot:null,rota:null};desenharAba()};
  $$("abLista").innerHTML=lista.length?lista.map(v=>cartao(v,eq)).join(""):'<div class="vazio">Nenhuma viagem aberta errada nesse período e filtro. 👍</div>';
  $$("abLista").querySelectorAll("[data-m]").forEach(b=>b.onclick=()=>marcar(b.dataset.v,b.dataset.m));
  if(A.foco){const el=$$("abLista").querySelector('[data-id="'+CSS.escape(A.foco)+'"]');A.foco=null;
    if(el){el.scrollIntoView({behavior:"smooth",block:"center"});el.style.outline="2px solid var(--brand)"}}
}
function rank(id,lista,chave,campo,fmt){
  const c={};lista.forEach(v=>c[chave(v)]=(c[chave(v)]||0)+1);
  const arr=Object.entries(c).sort((a,b)=>b[1]-a[1]).slice(0,8),max=arr.length?arr[0][1]:1,el=document.getElementById(id);
  el.innerHTML=arr.length?arr.map(([k,n])=>'<tr data-k="'+esc(k)+'" class="'+(A.filtro[campo]===k?"on":"")+'"><td>'+esc(fmt(k))+
    '<div class="barra"><i style="width:'+Math.round(100*n/max)+'%"></i></div></td><td class="n">'+n+'</td></tr>').join(""):'<tr><td class="note">—</td></tr>';
  el.querySelectorAll("tr[data-k]").forEach(t=>t.onclick=()=>{A.filtro[campo]=A.filtro[campo]===t.dataset.k?null:t.dataset.k;desenharAba()});
}
function cartao(v,eq){
  const ok=v.sit!=="aberto", r0=v.regras[0];
  return '<div class="ab-caso '+(ok?"ok":v.grav)+'" data-id="'+esc(v.viagem_id)+'"><div class="l1"><b>'+dm(v.data)+' '+esc(v.hora)+'</b><span>carro <b>'+esc(v.frota)+'</b></span>'+
    '<span>'+esc(nome(v.motorista))+'</span><b>'+esc(v.linha)+' · '+esc(v.tipo)+'</b>'+
    '<span class="note">'+(v.ocupacao==null?"sem leitura":v.ocupacao+" passageiro(s)")+' · '+esc(v.tipolinha)+'</span></div>'+
    '<ul>'+v.regras.map(r=>'<li><span class="ab-chip ab-'+r.gravidade+'">'+esc(REGRA[r.regra]||r.regra)+'</span> '+esc(r.problema)+'<span class="sg">→ '+esc(r.sugestao)+'</span></li>').join("")+'</ul>'+
    '<div class="acts"><span class="info">'+(v.sit==="falso"?'<span class="ab-chip ab-ok">Estava certa</span> ':v.sit==="corrigido"?'<span class="ab-chip ab-ok">Corrigida</span> ':'')+
      (r0.obs?esc(r0.obs)+' · ':'')+(ok&&r0.marcado_por?'por '+esc(r0.marcado_por)+' · ':'')+
      (v.avisado?'enviada na demanda #'+v.avisado.cartao_id+' em '+dtBR(v.avisado.avisado_em):'ainda não enviada para a demanda')+'</span>'+
    (eq?(ok?'<button class="btn sm" data-v="'+esc(v.viagem_id)+'" data-m="aberto">Reabrir</button>':
      '<button class="btn sm" data-v="'+esc(v.viagem_id)+'" data-m="corrigido">✓ Corrigida</button><button class="btn sm" data-v="'+esc(v.viagem_id)+'" data-m="falso">Estava certa</button>'):'')+
    '</div></div>';
}
async function marcar(id,sit){
  const v=viagens(A.dados).find(x=>x.viagem_id===id);if(!v)return;
  let obs=null;
  if(sit!=="aberto"){obs=prompt(sit==="falso"?"Por que estava certa? (ex.: carro extra, troca de escala)":"Observação (opcional)","");if(obs===null)return}
  try{for(const r of v.regras)await rpc("abt_marcar",{p_token:TOKEN,p_viagem:id,p_regra:r.regra,p_situacao:sit,p_obs:obs});A.ontemEm=0;carregarAba()}
  catch(e){alert(msgErro(e))}
}
function planilha(){
  if(!A.dados)return;
  const lin=[["Data","Hora","Carro","Motorista","Rota","Sentido","Grupo","Passageiros","Regra","Problema","O que fazer","Situação","Enviada em"]];
  for(const v of filtrar(viagens(A.dados)))for(const r of v.regras)
    lin.push([dBR(v.data),v.hora,v.frota,v.motorista,v.linha,v.tipo,v.tipolinha,v.ocupacao??"",REGRA[r.regra]||r.regra,r.problema,r.sugestao,r.situacao,r.avisado_em?dtBR(r.avisado_em):""]);
  const csv="﻿"+lin.map(l=>l.map(x=>{x=String(x??"");return /[;"\n]/.test(x)?'"'+x.replace(/"/g,'""')+'"':x}).join(";")).join("\r\n");
  const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));
  a.download="viagens-abertas-erradas_"+A.de+"_a_"+A.ate+".csv";a.click();
}

if(location.hash==="#aberturas")setTimeout(()=>{if(TOKEN)aba("abt");else{const t=setInterval(()=>{if(TOKEN){clearInterval(t);aba("abt")}},300);setTimeout(()=>clearInterval(t),15000)}},0);
})();
