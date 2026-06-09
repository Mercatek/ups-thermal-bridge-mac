/* Diagnostics: paste in DevTools Console on a UPS page to see whether the ZPL
 * (or the LabelRecovery endpoint) is reachable from the current page. Useful to
 * understand why a given UPS view can or cannot be captured.
 */
(() => {
  const found = [];
  const tryZpl = (s) => {
    if (typeof s !== 'string' || s.length < 60) return null;
    if (s.indexOf('^XA') > -1) return s;
    const m = s.match(/[A-Za-z0-9+/]{300,}={0,2}/g);
    if (m) for (const b of m) { try { if (atob(b).indexOf('^XA') > -1) return b; } catch (e) {} }
    return null;
  };
  const add = (z, w) => { if (z) found.push({ where: w, type: z.indexOf('^XA') > -1 ? 'raw' : 'b64', len: z.length }); };
  try { for (let i = 0; i < sessionStorage.length; i++) { const k = sessionStorage.key(i); add(tryZpl(sessionStorage.getItem(k)), 'sessionStorage:' + k); } } catch (e) {}
  try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); add(tryZpl(localStorage.getItem(k)), 'localStorage:' + k); } } catch (e) {}
  document.querySelectorAll('input,textarea').forEach((el, i) => add(tryZpl(el.value), 'field:' + (el.name || el.id || i)));
  try { add(tryZpl(document.body.innerHTML.slice(0, 5e6)), 'body.innerHTML'); } catch (e) {}
  console.log('%c[scan] ZPL found in page state:', 'font-weight:bold', found.length ? found : 'none');
  try {
    const apis = performance.getEntriesByType('resource').map(e => e.name).filter(n => /label|ship|print|graphic|thermal|recovery/i.test(n)).map(n => n.split('?')[0]);
    console.log('[scan] label-related network endpoints:', [...new Set(apis)]);
  } catch (e) {}
})();
