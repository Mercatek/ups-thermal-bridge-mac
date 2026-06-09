#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UPS Print Bridge for macOS
==========================
A tiny local HTTP service that lets you print UPS **thermal (ZPL) labels**
straight from ups.com to a CUPS printer (e.g. a Bixolon / Zebra label printer),
without the (Windows-only / Java-era) official "UPS Thermal Printing" app.

It works together with a Tampermonkey userscript (see ./userscript) that grabs
the label's ZPL from UPS's own `LabelRecovery` API and "stages" it here. When
you click **Print Thermal Label** on ups.com, UPS opens a hidden window that
navigates to this service (`/listPrinters`) — that is our cue to print the
staged ZPL with `lp`.

Endpoints
---------
  GET  /listPrinters   UPS hits this when you click "Print Thermal Label".
                       - Top-level navigation (the label window) + a staged ZPL
                         -> print it. Otherwise serve a tiny auto-closing page.
                       - fetch/XHR -> return the printer list as JSON.
  POST /stage          The userscript posts {trackingNumber, data:<zpl|base64>}.
  POST /print          Print arbitrary ZPL now (userscript floating button).
                       Accepts JSON / base64 / raw ^XA...^XZ.
  POST /probe          Diagnostics sink (logged only).
  GET  /favicon.ico    204.

Configuration (all optional, via environment variables)
  UPS_BRIDGE_PRINTER   CUPS queue name        (default: Bixolon_SRP770III)
  UPS_BRIDGE_PORT      port to listen on      (default: 4349)
  UPS_BRIDGE_HOST      interface              (default: 127.0.0.1)
  UPS_BRIDGE_RAW       "1" to use `lp -o raw` (default: 0)
  UPS_BRIDGE_LOG       log file path          (default: ~/Library/Logs/ups-print-bridge.log)

Not affiliated with or endorsed by UPS.
"""

import os
import re
import sys
import json
import time
import base64
import tempfile
import subprocess
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PRINTER = os.environ.get("UPS_BRIDGE_PRINTER", "Bixolon_SRP770III")
PORT = int(os.environ.get("UPS_BRIDGE_PORT", "4349"))
HOST = os.environ.get("UPS_BRIDGE_HOST", "127.0.0.1")
USE_RAW = os.environ.get("UPS_BRIDGE_RAW", "0") == "1"
LOG_PATH = os.environ.get(
    "UPS_BRIDGE_LOG", os.path.expanduser("~/Library/Logs/ups-print-bridge.log")
)

LP_BIN = "/usr/bin/lp"

# ZPL waiting to be printed: the userscript drops it here (POST /stage) and it
# is printed when you click "Print Thermal Label" (UPS navigates to /listPrinters).
STAGED = {"data": None, "tracking": None, "ts": 0}
STAGE_TTL = 1800  # seconds: never print a staged label older than this
LAST_LABEL_PATH = os.path.expanduser("~/Library/Logs/ups-last-label.zpl")

_B64_RE = re.compile(rb"^[A-Za-z0-9+/=\s]+$")


def log(msg):
    line = "%s  %s" % (datetime.datetime.now().isoformat(timespec="seconds"), msg)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)


# ---------------------------------------------------------------------------
# Pull ZPL out of an unknown-shaped body (JSON / base64 / raw / form-encoded)
# ---------------------------------------------------------------------------

def _decode_b64(s):
    raw = s.encode("utf-8", "ignore") if isinstance(s, str) else s
    raw = b"".join(raw.split())
    if len(raw) < 8 or not _B64_RE.match(raw):
        return None
    try:
        return base64.b64decode(raw + b"=" * ((-len(raw)) % 4))
    except Exception:
        return None


def _looks_like_zpl(b):
    return isinstance(b, (bytes, bytearray)) and b"^XA" in b


def _find_zpl_in_json(obj):
    stack = [obj]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)
        elif isinstance(cur, str):
            if "^XA" in cur:
                return cur.encode("utf-8", "ignore")
            dec = _decode_b64(cur)
            if _looks_like_zpl(dec):
                return dec
    return None


def _zpl_from_values(values):
    """First value that is ZPL (raw or base64), as bytes, or None."""
    for v in values:
        if not isinstance(v, str):
            continue
        if "^XA" in v:
            return v.encode("utf-8", "ignore")
        dec = _decode_b64(v)
        if _looks_like_zpl(dec):
            return dec
    return None


def extract_zpl(body_bytes, content_type):
    if not body_bytes:
        return None
    ctype = (content_type or "").lower()
    text = None
    try:
        text = body_bytes.decode("utf-8")
    except Exception:
        text = None
    if text is not None:
        stripped = text.lstrip()
        if stripped[:1] in ("{", "["):
            try:
                zpl = _find_zpl_in_json(json.loads(text))
                if zpl:
                    return zpl
            except Exception:
                pass
        if "^XA" in text:
            return text.encode("utf-8", "ignore")
        if "=" in text and ("&" in text or "urlencoded" in ctype):
            try:
                vals = [v for lst in parse_qs(text).values() for v in lst]
                zpl = _zpl_from_values(vals)
                if zpl:
                    return zpl
            except Exception:
                pass
        dec = _decode_b64(text)
        if _looks_like_zpl(dec):
            return dec
    if _looks_like_zpl(body_bytes):
        return body_bytes
    return None


def send_to_printer(zpl_bytes):
    """Send ZPL bytes to the printer via `lp`. Returns (ok, detail)."""
    tmp = tempfile.NamedTemporaryFile(prefix="ups_label_", suffix=".zpl", delete=False)
    try:
        tmp.write(zpl_bytes)
        tmp.flush()
        tmp.close()
        try:
            with open(LAST_LABEL_PATH, "wb") as fh:  # debug copy of last printed label
                fh.write(zpl_bytes)
        except Exception:
            pass
        cmd = [LP_BIN, "-d", PRINTER]
        if USE_RAW:
            cmd += ["-o", "raw"]
        cmd.append(tmp.name)
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        ok = proc.returncode == 0
        detail = ((proc.stdout or "") + (proc.stderr or "")).strip()
        log("PRINT cmd=%s rc=%s out=%s" % (" ".join(cmd), proc.returncode, detail))
        return ok, detail
    except Exception as exc:
        log("PRINT ERROR %r" % (exc,))
        return False, str(exc)
    finally:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# HTML served inside the hidden "label window" that UPS opens
# ---------------------------------------------------------------------------

INSTRUMENT_HTML = """<!doctype html><html><head><meta charset="utf-8">
<title>UPS Print Bridge</title></head>
<body style="font:14px -apple-system,Arial;padding:20px">
<h3>UPS Print Bridge</h3>
<p>Local print service is running. Waiting for label data&hellip;</p>
<script>
var PRINTER = %PRINTER%;
function probe(o){try{fetch('/probe',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o)});}catch(e){}}
function toServer(p,o){try{fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o)});}catch(e){}}
probe({event:'window_loaded',name:window.name,referrer:document.referrer,href:location.href,hasOpener:!!window.opener,query:location.search});
function announce(){
  var p={status:'ok',success:true,ready:true,source:'ups-print-bridge',
         printers:[{name:PRINTER,displayName:PRINTER,default:true,isDefault:true,status:'ready'}],defaultPrinter:PRINTER};
  try{ if(window.opener){ window.opener.postMessage(p,'*'); window.opener.postMessage(JSON.stringify(p),'*'); } }catch(e){}
  try{ if(window.parent&&window.parent!==window){ window.parent.postMessage(p,'*'); } }catch(e){}
}
announce(); setTimeout(announce,300); setTimeout(announce,1000);
setTimeout(function(){ try{ window.close(); }catch(e){} }, 2500);
window.addEventListener('message',function(e){
  var d=e.data, s; try{ s=(typeof d==='string')?d:JSON.stringify(d); }catch(_){ s=String(d); }
  probe({event:'message_in',origin:e.origin,preview:(s||'').slice(0,4000)});
  try{ if(s && (s.indexOf('^XA')!==-1 || /[A-Za-z0-9+\\/=]{200,}/.test(s))) toServer('/print',{data:s}); }catch(e2){}
});
</script></body></html>"""


def instrument_html():
    return INSTRUMENT_HTML.replace("%PRINTER%", json.dumps(PRINTER))


def print_done_html(ok, detail=""):
    color = "#2D7A4F" if ok else "#C53030"
    msg = "Label sent to the printer" if ok else "Could not print: " + detail
    return ("""<!doctype html><html><head><meta charset="utf-8"><title>UPS Print Bridge</title></head>
<body style="font:15px -apple-system,Arial;padding:24px;text-align:center;color:%s">
<h2>%s</h2><p>This window closes automatically&hellip;</p>
<script>setTimeout(function(){try{window.close();}catch(e){}},1500);</script>
</body></html>""" % (color, msg))


def list_printers_payload(query):
    one = {"name": PRINTER, "displayName": PRINTER.replace("_", " "), "default": True,
           "isDefault": True, "status": "ready", "connected": True, "type": "thermal"}
    printers = [one]
    return {
        "status": "ok", "success": True,
        "loc": (query.get("loc") or [""])[0], "app": (query.get("app") or [""])[0],
        "name": (query.get("name") or [""])[0],
        "defaultPrinter": PRINTER, "default": PRINTER,
        "printers": printers, "printerList": printers, "printersList": printers,
        "availablePrinters": printers, "data": printers,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _cors_headers(self):
        origin = self.headers.get("Origin", "*")
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS, DELETE")
        self.send_header("Access-Control-Allow-Headers", self.headers.get("Access-Control-Request-Headers", "*"))
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.send_header("Access-Control-Allow-Private-Network", "true")  # Chrome PNA
        self.send_header("Access-Control-Max-Age", "86400")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self._cors_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html, code=200):
        body = html.encode("utf-8")
        self.send_response(code)
        self._cors_headers()
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _is_navigation(self):
        return self.headers.get("Sec-Fetch-Dest", "") == "document" or \
            "text/html" in self.headers.get("Accept", "")

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        return self.rfile.read(n) if n > 0 else b""

    def _log_request(self, body=b""):
        log("REQ %s %s" % (self.command, self.path))
        if body:
            try:
                log("    body[%d]: %s" % (len(body), body[:600].decode("utf-8", "replace")))
            except Exception:
                log("    body[%d]: <binary>" % len(body))

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._log_request()
        parsed = urlparse(self.path)
        path = parsed.path.lower().rstrip("/")
        query = parse_qs(parsed.query)
        if path.endswith("favicon.ico"):
            self.send_response(204)
            self._cors_headers()
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # ZPL passed in the query string?
        zpl = _zpl_from_values([v for lst in query.values() for v in lst])
        if zpl:
            ok, detail = send_to_printer(zpl)
            self._send_json({"status": "ok" if ok else "error", "success": ok,
                             "printer": PRINTER, "bytes": len(zpl), "detail": detail},
                            code=200 if ok else 500)
            return
        if path.endswith("listprinters") or "printer" in path:
            if self._is_navigation():
                data = STAGED.get("data")
                age = time.time() - STAGED.get("ts", 0)
                if data and age <= STAGE_TTL:
                    z = _zpl_from_values([data])
                    if z:
                        ok, detail = send_to_printer(z)
                        log("    (label window -> printing staged ZPL tracking=%s len=%s ok=%s)"
                            % (STAGED.get("tracking"), len(z), ok))
                        self._send_html(print_done_html(ok, detail))
                        return
                if data:
                    log("    (label window but staged ZPL is stale %.0fs -> not printing)" % age)
                self._send_html(instrument_html())
            else:
                self._send_json(list_printers_payload(query))
        else:
            self._send_json({"status": "ok", "success": True, "service": "ups-print-bridge",
                             "version": "1.0", "defaultPrinter": PRINTER})

    def _handle_body_request(self):
        body = self._read_body()
        self._log_request(body)
        parsed = urlparse(self.path)
        ppath = parsed.path.lower().rstrip("/")
        query = parse_qs(parsed.query)
        if ppath.endswith("probe"):
            self._send_json({"status": "ok", "logged": True})
            return
        if ppath.endswith("stage"):
            try:
                obj = json.loads(body.decode("utf-8"))
                STAGED["data"] = obj.get("data")
                STAGED["tracking"] = obj.get("trackingNumber")
                STAGED["ts"] = time.time()
                log("    STAGED updated tracking=%s len=%s" % (STAGED["tracking"], len(STAGED["data"] or "")))
            except Exception as exc:
                log("    stage error %r" % (exc,))
            self._send_json({"status": "ok", "staged": bool(STAGED["data"])})
            return
        zpl = extract_zpl(body, self.headers.get("Content-Type", ""))
        if zpl:
            ok, detail = send_to_printer(zpl)
            self._send_json({"status": "ok" if ok else "error", "success": ok,
                             "printer": PRINTER, "bytes": len(zpl), "detail": detail},
                            code=200 if ok else 500)
        else:
            self._send_json(list_printers_payload(query))

    def do_POST(self):
        self._handle_body_request()

    def do_PUT(self):
        self._handle_body_request()


def main():
    log("=" * 70)
    log("UPS Print Bridge starting on http://%s:%d  printer=%s raw=%s" % (HOST, PORT, PRINTER, USE_RAW))
    log("Log: %s" % LOG_PATH)
    try:
        srv = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        log("ERROR opening port %d: %r" % (PORT, exc))
        sys.exit(1)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
