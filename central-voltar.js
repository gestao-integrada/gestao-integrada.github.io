/* Botão "← Central" das páginas do gestao-integrada.github.io (mesmo visual do da Central).
   Páginas internas: <script src="../central-voltar.js"></script> → aparece sozinho.
   Páginas com gente de fora (Visitas, Demandas): <script src="../central-voltar.js" data-manual></script>
   e a página chama tfVoltarCentral(true) só quando quem entrou é da equipe interna. */
(function () {
  var URL_CENTRAL = 'https://zael20.github.io/painel-mes-tfleet-bdv/central.html';
  var me = document.currentScript, manual = me && me.hasAttribute('data-manual');
  function botao() {
    var a = document.getElementById('tf-voltar-central');
    if (a) return a;
    a = document.createElement('a');
    a.id = 'tf-voltar-central'; a.href = URL_CENTRAL; a.textContent = '← Central';
    a.setAttribute('aria-label', 'Voltar à Central');
    a.style.cssText = 'position:fixed;z-index:2147483000;display:none;align-items:center;background:#2563eb;color:#fff;' +
      'text-decoration:none;font:800 15px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;padding:10px 18px;' +
      'border-radius:999px;line-height:1;border:2px solid #fff;box-shadow:0 4px 16px rgba(0,0,0,.3);' +
      'top:calc(10px + env(safe-area-inset-top,0px));left:calc(12px + env(safe-area-inset-left,0px));transition:transform .22s ease;';
    a.onmouseenter = function () { a.style.background = '#1d4ed8'; };
    a.onmouseleave = function () { a.style.background = '#2563eb'; };
    document.body.appendChild(a);
    var lastY = 0;
    window.addEventListener('scroll', function () {
      var y = window.pageYOffset || 0;
      a.style.transform = (y > lastY && y > 80) ? 'translateY(-160%)' : 'none'; lastY = y;
    }, { passive: true });
    return a;
  }
  var reservado = 0;
  window.tfVoltarCentral = function (mostrar) {
    var a = botao();
    a.style.display = mostrar ? 'inline-flex' : 'none';
    var cur = parseFloat(getComputedStyle(document.body).paddingTop) || 0;
    if (mostrar && !reservado) {
      var need = Math.ceil(a.getBoundingClientRect().bottom) + 8;
      if (cur < need) { reservado = need - cur; document.body.style.paddingTop = need + 'px'; }
    } else if (!mostrar && reservado) { document.body.style.paddingTop = (cur - reservado) + 'px'; reservado = 0; }
  };
  function ini() { if (!manual) window.tfVoltarCentral(true); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ini); else ini();
})();
