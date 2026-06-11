// Handshake.swift — the page served at GET /listPrinters. It reproduces the
// official app's labelWindow protocol: ask ups.com (window.opener) for the
// current label via postMessage, receive the base64 ZPL, POST it to /print.

import Foundation

func handshakeHTML() -> String {
    let printer = jsString(BridgeConfig.shared.printer)
    let labelType = jsString(BridgeConfig.shared.labelType)
    let port = "\(BridgeConfig.shared.port)"
    return TEMPLATE
        .replacingOccurrences(of: "%PRINTER%", with: printer)
        .replacingOccurrences(of: "%LABELTYPE%", with: labelType)
        .replacingOccurrences(of: "%PORT%", with: port)
}

private func jsString(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private let TEMPLATE = """
<!doctype html><html><head><meta charset="utf-8">
<title>UPS Print Bridge</title></head>
<body style="font:14px -apple-system,Arial;padding:18px">
<h3>UPS Print Bridge</h3>
<p id="s">Requesting the label from UPS&hellip;</p>
<script>
var PRINTER=%PRINTER%, LABELTYPE=%LABELTYPE%, PORT=%PORT%;
var q=new URLSearchParams(location.search);
var app=q.get('app')||''; var windowName=q.get('name')||window.name||'labelWindow';
var origin='*'; try{ if(app && app.slice(0,4)==='http'){ origin=new URL(app).origin; } }catch(e){}
function setS(t){var e=document.getElementById('s'); if(e) e.textContent=t;}
function probe(o){try{fetch('/probe',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o)});}catch(e){}}
probe({event:'handshake_loaded',app:app,windowName:windowName,origin:origin,hasOpener:!!window.opener});
function requestLabel(){
  var msg={requestType:'request',labelType:LABELTYPE,printer:PRINTER,windowName:windowName,version:'3.0.0'};
  try{ if(window.opener){ window.opener.postMessage(msg,origin); window.opener.postMessage(msg,'*'); } }catch(e){}
  try{ if(window.parent && window.parent!==window){ window.parent.postMessage(msg,'*'); } }catch(e){}
}
function looksLikeLabel(s){
  if(typeof s!=='string'||s.length<100) return false;
  if(s.indexOf('^XA')!==-1) return true;
  try{ return atob(s.replace(/[^A-Za-z0-9+/=]/g,'')).indexOf('^XA')!==-1; }catch(e){ return false; }
}
var printed=false;
function gotLabel(data){
  if(printed) return; printed=true; setS('Printing on '+PRINTER+'…');
  probe({event:'label_received',len:(data||'').length});
  var body='printerName='+encodeURIComponent(PRINTER)+'&labelBytes='+encodeURIComponent(data);
  var x=new XMLHttpRequest();
  x.onreadystatechange=function(){ if(this.readyState===4){ setS('Sent to the printer.');
    try{ if(window.opener) window.opener.postMessage({requestType:'response',query:this.response},origin);}catch(e){}
    setTimeout(function(){try{window.close();}catch(e){}},1500); } };
  x.open('POST','http://127.0.0.1:'+PORT+'/print',true);
  x.setRequestHeader('Content-type','application/x-www-form-urlencoded');
  x.send(body);
}
window.addEventListener('message',function(e){
  var d=e.data, cand=null;
  if(typeof d==='string') cand=d;
  else if(d && typeof d==='object') cand=d.labelBytes||d.data||d.label||d.content||d.zpl;
  if(looksLikeLabel(cand)){ probe({event:'msg_label',origin:e.origin}); gotLabel(cand); }
});
requestLabel(); setTimeout(requestLabel,400); setTimeout(requestLabel,1200);
setTimeout(function(){ if(!printed){ setS('No label received from UPS in this window.'); } },9000);
</script></body></html>
"""
