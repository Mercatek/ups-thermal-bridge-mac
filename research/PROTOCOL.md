# The UPS local thermal-print protocol (port 4349) — reverse-engineered

Reconstructed by static analysis of the official **macOS** app
`UPS Thermal Printing.app` v3.0.0 (2018), bundle id `com.ups.iss.printers`,
a Java app (`ThermalApp_Test.jar`, main class
`com.ups.iss.printers.ThermalPrintController`) bundled with a JRE 8.
Class constant pools were parsed directly (no JDK available to run `javap`).

This documents what ups.com talks to so the flow can be reproduced natively on
any OS — including the **Shipping History "Get Labels"** flow, which the
Tampermonkey approach can't capture.

## The local HTTP server

`ThermalPrintController$ThermalHttpServer` is a `com.sun.net.httpserver.HttpServer`
listening on **127.0.0.1:<port>** (port from CLI arg / `UPSThermalPrinting.properties`;
observed default **4349**). It registers three **prefix** contexts:

| Context (prefix) | Handler | Purpose |
|---|---|---|
| `/list`  | `ListHandler`  | matches `/listPrinters` → returns the **label-window HTML** |
| `/print` | `PrintHandler` | receives the label bytes and prints |
| `/ping`  | `PingHandler`  | liveness check |

Every response runs `checkHeaders`: it reads the `Origin`/`Host` request
headers, requires the host to be `127.0.0.1`/`localhost`, and echoes
**`Access-Control-Allow-Origin: <origin>`** (so the browser may read responses).

Single-instance: if the port is already bound it logs *"instance already bound
to port …, exiting"* and quits.

## `GET /listPrinters` — returns an HTML page (NOT JSON)

Query params (all optional): `loc` (locale → language/country), `app` (caller,
e.g. `https://www.ups.com`), `name` (the window name, e.g. `labelWindow`),
`pref` (preferred printer), `edge` (Edge-browser PCL hint).

It enumerates local print services, classifies each into a
`ThermalPrinterType`, builds a `<select id='thermalPrinters'>` of
`<option value='<pcl>' label='<printerName>'>`, and returns the
**`HTML_TEMPLATE`** page (see `labelwindow_template.html`). That page is what
renders inside the popup window UPS opens. Its embedded JS is the real protocol:

```js
// (decompiled, simplified — {1}=port, {8}=opener origin e.g. https://www.ups.com)
function requestPcl() {                       // after the user picks a printer
  var pclType = document.getElementById("thermalPrinterType").value;  // e.g. "zpl"
  var printer = document.getElementById("thermalPrinterName").value;
  window.opener.postMessage(
    { requestType:"request", labelType:pclType, printer:printer,
      windowName:window.name, version:"3.0.0" }, "{8}");
}
function waitForButtonClick() {               // when a click is required first
  window.opener.postMessage({ requestType:"wait" }, "{8}");
}
function receiveMessage(event) {              // ups.com sends the label here
  var printerName = document.getElementById("thermalPrinterName").value;
  var query = "printerName=" + printerName + "&labelBytes=" + event.data;
  var xhr = new XMLHttpRequest();
  xhr.onreadystatechange = function () {
    if (this.readyState === 4)
      window.opener.postMessage({ requestType:"response", query:this.response }, "{8}");
  };
  xhr.open("POST", "http://127.0.0.1:{1}/print", true);
  xhr.responseType = "text";
  xhr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
  xhr.send(query);
}
window.addEventListener("message", receiveMessage, false);
```

### The handshake (this is the whole thing)

```
ups.com                                  popup = http://127.0.0.1:4349/listPrinters
   │  window.open(.../listPrinters?...&name=labelWindow, "labelWindow")
   │ ───────────────────────────────────────────────▶  (loads HTML_TEMPLATE)
   │                                                    user/auto picks printer
   │   postMessage {requestType:"request",             │
   │ ◀───────────── labelType:"zpl", printer, ... } ───┘
   │  (ups.com now knows it must produce a ZPL label)
   │   postMessage( <base64 label bytes> )  ─────────▶  receiveMessage(event)
   │                                                    POST /print
   │                                                      printerName=..&labelBytes=<b64>
   │                                                    ───────────────▶ prints
   │   postMessage {requestType:"response", query} ◀──  (print result)
```

**Key consequence:** the label bytes arrive at the popup via `postMessage`
**from ups.com**, *regardless of how the user reached printing* (label page or
Shipping History). So a faithful re-implementation of `/listPrinters` makes the
**history flow work too**, with no userscript — the missing piece in the
userscript approach was simply that `/listPrinters` must return this HTML
handshake page, not JSON.

## `POST /print` — prints the label

Body is `application/x-www-form-urlencoded`: `printerName=<name>&labelBytes=<base64>`.
Handler `PrintHandler` reads the body line, parses the params, **Base64-decodes
`labelBytes`** (`com.ups.iss.printers.Base64`), and prints the raw bytes via
`javax.print` (`SimpleDoc` + `DocFlavor.BYTE_ARRAY.AUTOSENSE`) to the named
print service. It replies with a form-encoded result string:

```
status=<OK|FAILED|Error>&name=<printerName>&target=HttpApp&version=3.0.0&cause=<msg>
```

(Our bridge instead pipes the decoded bytes to `lp -d <printer>`, which is the
CUPS-native equivalent.)

## `GET /ping` — liveness

Returns a small OK response; used by the page to detect the service is present.

## Printer types → format code (`pcl`) sent to ups.com

From `ThermalPrinterType` (matched by case-insensitive substring of the printer
name; `pcl` is the `<option value>` / `labelType` sent to ups.com):

| Type | name contains | `pcl` (labelType) |
|---|---|---|
| ZEBRA | `zebra` | `zpl` |
| ELTRON | `eltron` | `epl2` |
| BIXOLON | `bixolon` | `spl` |
| BIXOLONSRP | `bixolon srp` | (SRP variant) |
| UPS | `ups thermal` | — |
| SAMSUNG | `samsung` | — |
| STAR | `star tsp800l peeler` / `star` | `star` |
| OKI / OKI2 | `oki ld610` / `ld620d` | — |
| DATAMAX | `datamax` | — |
| INTERMEC | `honeywell` | — |

To get **ZPL** (what our pipeline wants), advertise the printer with
`labelType = zpl` (i.e. a Zebra-class option). A raw CUPS queue then prints the
ZPL bytes verbatim.

## macOS specifics found in the app

- `MacApplicationHandler` runs `cupsctl` (`cupsctl WebInterface=yes`) and opens
  `http://localhost:631/printers/` to help the user set up a raw CUPS queue.
- Printer discovery uses `javax.print.PrintServiceLookup` (CUPS queues).
- It also ships a Java **applet** (`PrinterApplet`, *"UPS Thermal Printer Applet
  Ver: 5"*) for the legacy Safari/NPAPI path: the applet takes `thermalContent`
  (base64 ZPL) as a parameter and prints via `javax.print` — the same idea,
  pre-`postMessage`.

## Why the official macOS app is a dead end today

- Built **2018**, bundles **JRE 8 (x86)**, unsigned/not-notarized, and the
  Safari path depends on **Java applets / NPAPI** — all removed from modern
  macOS. It will not run on current macOS / Apple Silicon.
- Therefore re-implementing the protocol above (as this project does) is the
  correct path on modern macOS, not trying to run the old app.
