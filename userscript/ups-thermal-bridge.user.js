// ==UserScript==
// @name         UPS Thermal Label → Local Printer (ZPL bridge)
// @namespace    https://github.com/Mercatek/ups-thermal-bridge-mac
// @version      3.5
// @description  Grabs the ZPL of the UPS label you are viewing (via UPS's own LabelRecovery API) and prints it on your local thermal printer through the companion local service (port 4349). Lets you print UPS thermal labels on macOS without the official Windows-only app.
// @author       ups-thermal-bridge-mac
// @match        https://www.ups.com/*
// @match        https://*.ups.com/*
// @run-at       document-start
// @grant        GM_xmlhttpRequest
// @grant        unsafeWindow
// @connect      127.0.0.1
// @connect      localhost
// ==/UserScript==

/*
 * HOW IT WORKS
 * 1. On a label page (https://www.ups.com/uel/llp/<tracking>?...), UPS calls its
 *    own API `webapis.ups.com/uel/api/LabelRecovery` to render the label.
 * 2. This script takes that exact request, switches labelFormat to "zpl",
 *    downloads the ZPL, and "stages" it in the local service (POST /stage).
 * 3. When you click "Print Thermal Label", UPS opens a hidden window that
 *    navigates to http://127.0.0.1:4349/listPrinters -> the local service then
 *    prints the staged ZPL. One label per click; always the current label.
 *
 * The floating "Print to thermal printer" button prints the captured label
 * immediately (handy for an extra copy, or if you skip UPS's print button).
 *
 * NOTE: this only works on the label page itself (/uel/llp/...). If you click
 * "Get Labels" straight from Shipping History, UPS never loads the label on the
 * page, so there is nothing to capture — open the label first, then print.
 *
 * Uses GM_xmlhttpRequest so the cross-origin / mixed-content call to
 * http://127.0.0.1:4349 is not blocked by the browser.
 * Not affiliated with or endorsed by UPS.
 */

(function () {
  'use strict';

  var BRIDGE = 'http://127.0.0.1:4349';
  var DEBUG = true;   // logs to the browser console + the local service log

  var W = (typeof unsafeWindow !== 'undefined' && unsafeWindow) ? unsafeWindow : window;
  var origFetch = (W.fetch ? W.fetch.bind(W) : (window.fetch ? window.fetch.bind(window) : null));

  var labels = {};       // trackingNumber -> captured ZPL
  var currentZpl = null; // ZPL of the label currently loaded / staged
  var currentTn = null;
  var inflight = {};      // trackingNumber -> download in progress
  var lastPageTn = null;  // last tracking seen (to detect label switches)

  function log() { if (DEBUG) { try { console.log.apply(console, ['[UPS->Printer]'].concat([].slice.call(arguments))); } catch (e) {} } }

  function toast(msg, ok) {
    try {
      var d = document.createElement('div');
      d.textContent = msg;
      d.style.cssText = 'position:fixed;z-index:2147483647;bottom:66px;right:20px;padding:11px 16px;border-radius:8px;' +
        'font:600 14px/1.3 -apple-system,Arial,sans-serif;color:#fff;box-shadow:0 4px 16px rgba(0,0,0,.3);' +
        'background:' + (ok ? '#2D7A4F' : '#C53030') + ';';
      (document.body || document.documentElement).appendChild(d);
      setTimeout(function () { d.style.transition = 'opacity .4s'; d.style.opacity = '0'; }, 3000);
      setTimeout(function () { try { d.remove(); } catch (e) {} }, 3500);
    } catch (e) {}
  }

  var B64_RE = /^[A-Za-z0-9+/=\s]+$/;
  function findZpl(obj) {
    var stack = [obj], guard = 0;
    while (stack.length && guard < 100000) {
      guard++;
      var cur = stack.pop();
      if (cur && typeof cur === 'object') { for (var k in cur) { try { stack.push(cur[k]); } catch (e) {} } }
      else if (typeof cur === 'string') {
        if (cur.indexOf('^XA') !== -1) return cur;
        if (cur.length > 200 && B64_RE.test(cur)) { try { if (atob(cur.replace(/\s+/g, '')).indexOf('^XA') !== -1) return cur; } catch (e) {} }
      }
    }
    return null;
  }
  function extractZpl(text) {
    if (!text) return null;
    var t = text.replace(/^\)\]\}',?\s*/, '');  // strip anti-JSON-hijack prefix
    try { var z = findZpl(JSON.parse(t)); if (z) return z; } catch (e) {}
    if (text.indexOf('^XA') !== -1) return text;
    var m = text.match(/[A-Za-z0-9+/]{300,}={0,2}/g);
    if (m) for (var i = 0; i < m.length; i++) { try { if (atob(m[i]).indexOf('^XA') !== -1) return m[i]; } catch (e) {} }
    return null;
  }

  function toBridge(path, payload, onok, onko) {
    var body = JSON.stringify(payload);
    if (typeof GM_xmlhttpRequest === 'function') {
      GM_xmlhttpRequest({
        method: 'POST', url: BRIDGE + path, headers: { 'Content-Type': 'application/json' }, data: body,
        onload: function (r) { (r.status >= 200 && r.status < 300) ? (onok && onok(r)) : (onko && onko(r.status)); },
        onerror: function (e) { onko && onko(e); }
      });
    } else if (origFetch) {
      origFetch(BRIDGE + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body })
        .then(function (r) { r.ok ? (onok && onok(r)) : (onko && onko(r.status)); }).catch(function (e) { onko && onko(e); });
    }
  }

  function report(ev, extra) { try { var p = { src: 'us', ev: ev }; if (extra) for (var k in extra) p[k] = extra[k]; toBridge('/probe', p); } catch (e) {} }
  var lastTick = '';

  // tracking number of the label currently shown (URL: /uel/llp/1Z...)
  function pageTracking() {
    var m = (location.href.match(/1Z[A-Z0-9]{16}/i));
    return m ? m[0].toUpperCase() : null;
  }

  // Build a LabelRecovery URL straight from the page URL params (last resort).
  function buildLabelRecoveryUrl() {
    var m = location.pathname.match(/\/uel\/llp\/(1Z[A-Z0-9]+)/i);
    if (!m) return null;
    var tn = m[1].toUpperCase();
    var p;
    try { p = new URLSearchParams(location.search); } catch (e) { return null; }
    var id = p.get('id'), key = p.get('key'), loc = p.get('loc') || 'en_US';
    if (!id || !key) return null;
    var idB64; try { idB64 = btoa(id); } catch (e) { idB64 = id; }
    return {
      tn: tn,
      url: 'https://webapis.ups.com/uel/api/LabelRecovery?trackingNumber=' + encodeURIComponent(tn) +
           '&loc=' + encodeURIComponent(loc) + '&labelFormat=zpl&id=' + encodeURIComponent(idB64) +
           '&key=' + encodeURIComponent(key)
    };
  }

  // LabelRecovery URLs already requested by the page (most recent last)
  function labelRecoveryUrls() {
    try { return performance.getEntriesByType('resource').map(function (e) { return e.name; }).filter(function (n) { return /LabelRecovery/i.test(n); }); }
    catch (e) { return []; }
  }

  function fetchText(url) {
    if (origFetch) return origFetch(url, { credentials: 'include' }).then(function (r) { return r.text(); });
    return new Promise(function (res, rej) {
      if (typeof GM_xmlhttpRequest === 'function') GM_xmlhttpRequest({ method: 'GET', url: url, onload: function (r) { res(r.responseText); }, onerror: rej });
      else rej('no-fetch');
    });
  }

  function clearStage(tn) { currentZpl = null; currentTn = null; toBridge('/stage', { trackingNumber: tn || '', data: null }); }

  function syncStage(tn, zpl, announce) {
    currentZpl = zpl; currentTn = tn;
    toBridge('/stage', { trackingNumber: tn, data: zpl },
      function () { if (announce) { log('label ready:', tn, '(' + zpl.length + ' chars)'); toast('Label ready to print', true); } },
      function (e) { log('/stage error', e); });
  }

  function tryCandidates(tn, list, i) {
    if (i >= list.length) { inflight[tn] = false; report('cand_none', { tn: tn }); return; }
    fetchText(list[i]).then(function (t) {
      var zpl = extractZpl(t);
      if (zpl) { labels[tn] = zpl; inflight[tn] = false; report('captured', { tn: tn, len: zpl.length, via: i }); syncStage(tn, zpl, true); }
      else { report('cand_fail', { tn: tn, i: i, len: (t || '').length }); tryCandidates(tn, list, i + 1); }
    }).catch(function (e) { report('cand_err', { tn: tn, i: i }); tryCandidates(tn, list, i + 1); });
  }

  function captureCurrent() {
    var tn = pageTracking();
    var urlsAll = labelRecoveryUrls();
    var match = !!(tn && urlsAll.some(function (u) { return u.indexOf(tn) !== -1; }));
    var tick = (tn || '-') + ':' + urlsAll.length + ':' + match;
    if (tick !== lastTick) { lastTick = tick; report('tick', { tn: tn, lr: urlsAll.length, match: match, staged: !!currentZpl }); }

    if (!tn) return;  // only capture on label pages (/uel/llp/<tn>)

    // switched labels? clear the previous one so it is never printed by mistake
    if (tn !== lastPageTn) { lastPageTn = tn; if (!labels[tn]) clearStage(tn); }

    if (labels[tn]) { if (currentTn !== tn) syncStage(tn, labels[tn], false); return; }
    if (inflight[tn]) return;

    // candidates: the REAL LabelRecovery URLs the page used, filtered by THIS tracking
    var cands = urlsAll.filter(function (u) { return u.indexOf(tn) !== -1; })
                       .map(function (u) { return u.replace(/labelFormat=\w+/i, 'labelFormat=zpl'); });
    var built = buildLabelRecoveryUrl();   // last resort: built from the page URL
    if (built && built.tn === tn) cands.push(built.url);
    cands = cands.filter(function (v, i, a) { return a.indexOf(v) === i; });
    if (!cands.length) return;  // no URL yet; the next tick retries once the page calls LabelRecovery

    inflight[tn] = true;
    report('trying', { tn: tn, n: cands.length });
    tryCandidates(tn, cands, 0);
  }

  // Also capture the ZPL from any network response (belt and suspenders)
  function handleResponseText(t, url) {
    try {
      if (!t || t.length < 60) return;
      if (t.indexOf('^XA') === -1 && !/[A-Za-z0-9+/]{300,}={0,2}/.test(t)) return;
      var zpl = extractZpl(t);
      if (!zpl) return;
      var tn = pageTracking() || ('net-' + zpl.length);
      if (pageTracking()) labels[pageTracking()] = zpl;
      report('captured_net', { tn: tn, len: zpl.length });
      syncStage(tn, zpl, true);
    } catch (e) {}
  }
  if (origFetch) {
    W.fetch = function () {
      var a = arguments, p = origFetch.apply(this, a);
      try { var url = (a[0] && a[0].url) ? a[0].url : a[0]; p.then(function (r) { try { r.clone().text().then(function (t) { handleResponseText(t, url); }).catch(function () {}); } catch (e) {} }); } catch (e) {}
      return p;
    };
  }
  try {
    var XHR = W.XMLHttpRequest, RO = XHR.prototype.open, RS = XHR.prototype.send;
    XHR.prototype.open = function (m, u) { this.__u = u; return RO.apply(this, arguments); };
    XHR.prototype.send = function () { var s = this; this.addEventListener('load', function () { try { handleResponseText(s.responseText, s.__u); } catch (e) {} }); return RS.apply(this, arguments); };
  } catch (e) {}

  setInterval(captureCurrent, 1500);
  setTimeout(captureCurrent, 800);

  function addButton() {
    if (document.getElementById('ups-printer-btn')) return;
    var b = document.createElement('button');
    b.id = 'ups-printer-btn';
    b.textContent = '🖨️ Print to thermal printer';
    b.style.cssText = 'position:fixed;z-index:2147483647;bottom:20px;right:20px;padding:12px 16px;border:none;border-radius:8px;' +
      'cursor:pointer;font:700 14px -apple-system,Arial,sans-serif;color:#fff;background:#0D2B4E;box-shadow:0 3px 12px rgba(0,0,0,.35);';
    b.onclick = function () {
      if (!currentZpl) { toast('Label not captured yet (wait 1-2 s)', false); captureCurrent(); return; }
      toBridge('/print', { format: 'zpl', source: 'button', data: currentZpl },
        function () { toast('Sent to the printer', true); }, function () { toast('Print error (is the service running?)', false); });
    };
    (document.body || document.documentElement).appendChild(b);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addButton);
  else addButton();

  log('UPS thermal bridge v3.5 active. bridge=' + BRIDGE);
  report('loaded', { href: location.href, gm: (typeof GM_xmlhttpRequest === 'function') });
})();
