# UPS Thermal Label Bridge for macOS

Print **UPS thermal (ZPL) shipping labels** straight from **ups.com** to your
USB thermal label printer on **macOS** — without the official "UPS Thermal
Printing" app (which is Windows-only in practice / a dead Java‑era app on
modern macOS).

Tested on macOS (Apple Silicon) with Google Chrome and a Bixolon SRP‑770III.
It should work with any label printer that accepts **ZPL** through a CUPS *raw*
queue (most Zebra/Bixolon/Eltron‑style printers).

> Not affiliated with or endorsed by UPS. Use at your own risk.

---

## Does this solve your problem?

This is for you if, on a **Mac**, you've run into any of these:

- Clicking **"Print Thermal Label"** on **ups.com** does nothing, or opens an empty/blank window.
- The official **UPS Thermal Printing** app is **Windows-only**, or the old Mac/Java version won't run on modern macOS / **Apple Silicon**.
- You need to print **UPS ZPL labels** to a **Bixolon, Zebra or Eltron** thermal printer straight from the browser.
- UPS expects a local helper on **`127.0.0.1:4349`** that doesn't exist on your Mac.
- **QZ Tray** / WebSocket printing keeps getting blocked by Chrome (Private Network Access).

> Search terms: *UPS thermal label macOS*, *print UPS ZPL label on Mac*, *UPS Thermal Printing app Mac alternative*, *UPS print thermal label not working Mac*, *UPS 127.0.0.1:4349 Mac*, *Bixolon/Zebra UPS label Chrome Mac*.

---

## The problem

When you click **Print Thermal Label** on ups.com, the browser tries to reach a
local helper app on `http://127.0.0.1:4349`. That helper only ships for Windows;
the old macOS build relies on Java applets and NPAPI plugins that no longer
exist. So on a Mac, clicking *Print Thermal Label* does nothing useful.

Meanwhile, UPS already has the label as **ZPL**: it fetches it from its own API
`https://webapis.ups.com/uel/api/LabelRecovery?...&labelFormat=zpl`, and your
printer prints ZPL perfectly fine via `lp`. This project bridges the two.

## How it works

This project re-implements the **exact protocol** of the official "UPS Thermal
Printing" app (recovered by reverse-engineering it — see [`research/`](research/)).
When you click **Print Thermal Label**, UPS opens a small window pointed at
`http://127.0.0.1:4349/listPrinters`; the service answers with a page that asks
ups.com for the current label and prints it:

```
  ups.com  ──── window.open(.../listPrinters?...) ───▶  local service :4349
                                                         (Python, LaunchAgent)
                                                              │ serves a page that…
     ◀──── postMessage {requestType:"request", ───────────────┘
     │      labelType:"zpl", ...}
     │
     │ ──── postMessage(<base64 label for THIS shipment>) ──▶  page POSTs /print
     │                                                              │ lp -d <printer>
     │                                                              ▼
     │                                                       your thermal printer
```

Because ups.com hands over the **current** label every time, you always get the
right one — including from **Shipping History → "Get Labels"**.

The pieces:

1. **`ups_print_bridge.py`** — a tiny local HTTP service on port `4349`
   (runs as a LaunchAgent, starts on login). On `GET /listPrinters` it serves
   the handshake page; on `POST /print` it Base64-decodes the label and prints
   it with `lp`. It de-dupes identical labels so nothing prints twice.
2. **`userscript/ups-thermal-bridge.user.js`** *(optional)* — a Tampermonkey
   userscript that, on a label page, also grabs the ZPL from UPS's
   `LabelRecovery` API and adds a **🖨️ Print to thermal printer** button for an
   extra manual copy. The handshake works without it; the userscript is just a
   convenience.

The local call from `https://ups.com` to `http://127.0.0.1:4349` succeeds where
a WebSocket approach (e.g. QZ Tray) gets blocked by Chrome's Private Network
Access, because here ups.com talks to the service via a same-origin page +
`postMessage`, exactly as the official app intended.

---

## Requirements

- macOS with **Python 3** (`python3 --version`; install via `xcode-select --install` if missing).
- Your thermal printer added to **CUPS as a raw queue** (see below).
- **Google Chrome** (recommended) with the **Tampermonkey** extension.

## Install

### 1. Add your printer to CUPS as a *raw* queue

The printer must accept ZPL pass‑through. The easiest way:

1. Connect the printer by USB and turn it on.
2. Open `http://localhost:631/admin` in a browser → **Add Printer**.
3. Pick your printer under **Local Printers** → Continue.
4. Give it a simple **Name** (no spaces), e.g. `Bixolon_SRP770III` — remember it.
5. For **Make**, choose **Raw**; for **Model**, choose **Raw Queue**. → Add Printer.

Verify it prints ZPL:

```bash
printf '^XA^FO50,50^ADN,36,20^FDtest^FS^XZ' | lp -d YOUR_PRINTER_NAME
```

> Tip: if CUPS web admin is locked, run `cupsctl WebInterface=yes` first.

### 2. Install the local service

```bash
git clone https://github.com/Mercatek/ups-thermal-bridge-mac.git
cd ups-thermal-bridge-mac
./install.sh "YOUR_PRINTER_NAME"      # omit the name to use Bixolon_SRP770III
```

This copies the service to `~/Library/Application Support/UPSPrintBridge/`,
installs a LaunchAgent (`com.ups-print-bridge`) that starts on login, and runs
a smoke test. The script lives outside `~/Documents` on purpose — `launchd`
cannot read TCC‑protected folders.

### 3. (Optional) Install the userscript

Not required — the print flow works with just the service. Install it only if
you want the floating **🖨️ Print to thermal printer** button on label pages:

1. Install **Tampermonkey** in Chrome.
2. Tampermonkey → **Create a new script** → delete the template → paste the
   contents of [`userscript/ups-thermal-bridge.user.js`](userscript/ups-thermal-bridge.user.js) → **⌘S**.

---

## Usage

Just click **Print Thermal Label** on ups.com — from a label page **or** from
**Shipping History → "Get Labels"**. The service grabs the current label from
ups.com and prints it on your thermal printer. No userscript needed.

A small window flashes open ("Requesting the label from UPS… → Sent to the
printer.") and closes itself. It always prints the label for the shipment you
just chose, and never prints the same label twice in a row.

> Format: the service advertises the printer as Zebra-class so UPS sends **ZPL**.
> Change it with `UPS_BRIDGE_LABELTYPE` if your printer needs a different code
> (e.g. `epl2`, `spl`) — see [`research/PROTOCOL.md`](research/PROTOCOL.md).

### Optional: the userscript
The Tampermonkey userscript isn't required. Install it only if you want the
floating **🖨️ Print to thermal printer** button on label pages (handy for an
extra copy). The main flow works without it.

### If a particular shipment doesn't print
The window will say *"No label received from UPS"* instead of printing the wrong
label. Open that shipment's **label page** (`/uel/llp/...`) and try again.

## How it was built (reverse-engineering)

The `:4349` protocol was recovered by statically analysing the official app —
see [`research/`](research/): [`PROTOCOL.md`](research/PROTOCOL.md) (the full
protocol), [`REVERSE-ENGINEERING.md`](research/REVERSE-ENGINEERING.md) (method
and conclusions), and `labelwindow_template.html` (the verbatim handshake page).
TL;DR: the official macOS app is a 2018 Java/applet app that can't run on
modern macOS, so re-implementing its protocol is the right approach.

## Configuration

The service reads these environment variables (set in the LaunchAgent plist,
or re-run `./install.sh "Printer_Name"`):

| Variable | Default | Meaning |
|---|---|---|
| `UPS_BRIDGE_PRINTER` | `Bixolon_SRP770III` | CUPS queue name |
| `UPS_BRIDGE_PORT` | `4349` | Port to listen on |
| `UPS_BRIDGE_HOST` | `127.0.0.1` | Interface |
| `UPS_BRIDGE_RAW` | `0` | `1` → use `lp -o raw` |

In the userscript, `DEBUG = true` logs `[UPS->Printer]` lines to the browser
console.

## Troubleshooting

```bash
# Is the service listening?
lsof -nP -iTCP:4349 -sTCP:LISTEN

# Agent status (column 2 is the last exit code; 0 = OK)
launchctl list | grep ups-print-bridge

# Restart after editing the Python file
cp ups_print_bridge.py ~/Library/Application\ Support/UPSPrintBridge/
launchctl kickstart -k gui/$(id -u)/com.ups-print-bridge

# Live log (watch while you print)
tail -f ~/Library/Logs/ups-print-bridge.log

# The last ZPL actually sent to the printer (for inspection)
cat ~/Library/Logs/ups-last-label.zpl
```

- **Window says "No label received from UPS"** → that shipment's label wasn't
  delivered; open its label page (`/uel/llp/...`) and try again. Watch the log
  for `handshake_loaded` / `label_received`.
- **Blank label** → your CUPS queue is probably not *raw*; re-add it as Raw/Raw Queue.
- **`Failed to fetch` the very first time** → Chrome's Private Network Access
  warms up on the first request; just try again.
- **(Userscript) floating button does nothing** → make sure Tampermonkey is
  enabled on `ups.com`; open the console and look for `[UPS->Printer]`.

## Uninstall

```bash
./uninstall.sh
```

…and remove the userscript in Tampermonkey.

## Tools (optional, for debugging)

- [`tools/console-print.js`](tools/console-print.js) — paste in the DevTools
  console on a label page to fetch + print the current label once (no
  Tampermonkey needed).
- [`tools/console-scan.js`](tools/console-scan.js) — shows whether the ZPL /
  LabelRecovery endpoint is reachable from the current page.

## Disclaimer

This is an unofficial, community tool. It does not modify UPS data; it only
re-requests the label your account is already allowed to view and forwards it to
your local printer. Trademarks belong to their owners.
