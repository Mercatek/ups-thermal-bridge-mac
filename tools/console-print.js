/* One-shot tester (no Tampermonkey needed).
 * Open the UPS label page (https://www.ups.com/uel/llp/...), open DevTools
 * (F12) -> Console, paste this, press Enter. It re-fetches the label as ZPL
 * and sends it to the local print service, which prints it on your printer.
 */
(async () => {
  const RE = /[A-Za-z0-9+/]{300,}={0,2}/g;
  const find = o => { const s=[o]; let g=0; while(s.length && g++<1e5){ const c=s.pop();
    if(c && typeof c==='object'){ for(const k in c){ try{ s.push(c[k]); }catch(e){} } }
    else if(typeof c==='string'){ if(c.indexOf('^XA')>-1) return c;
      if(c.length>200 && /^[A-Za-z0-9+/=\s]+$/.test(c)){ try{ if(atob(c.replace(/\s+/g,'')).indexOf('^XA')>-1) return c; }catch(e){} } } }
    return null; };
  let url = performance.getEntriesByType('resource').map(e=>e.name).find(n=>/LabelRecovery/i.test(n));
  if(!url){ console.warn('[ups] No LabelRecovery request found. Reload the label page and retry.'); return; }
  url = url.replace(/labelFormat=\w+/i, 'labelFormat=zpl');
  const r = await fetch(url, { credentials:'include' });
  const t = await r.text();
  let zpl = find((()=>{ try{ return JSON.parse(t); }catch(e){ return t; } })());
  if(!zpl && t.indexOf('^XA')>-1) zpl = t;
  if(!zpl){ const m=t.match(RE); if(m) for(const b of m){ try{ if(atob(b).indexOf('^XA')>-1){ zpl=b; break; } }catch(e){} } }
  if(!zpl){ console.warn('[ups] No ZPL found in the response. First 300 chars:', t.slice(0,300)); return; }
  const p = await fetch('http://127.0.0.1:4349/print', { method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ format:'zpl', source:'console', data: zpl }) });
  console.log('%c[ups] ZPL sent to the printer (status '+p.status+'). Check the printer.', 'color:green;font-weight:bold');
})();
