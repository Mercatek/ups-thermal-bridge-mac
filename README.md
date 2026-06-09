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

## The problem

When you click **Print Thermal Label** on ups.com, the browser tries to reach a
local helper app on `http://127.0.0.1:4349`. That helper only ships for Windows;
the old macOS build relies on Java applets and NPAPI plugins that no longer
exist. So on a Mac, clicking *Print Thermal Label* does nothing useful.

Meanwhile, UPS already has the label as **ZPL**: it fetches it from its own API
`https://webapis.ups.com/uel/api/LabelRecovery?...&labelFormat=zpl`, and your
printer prints ZPL perfectly fine via `lp`. This project bridges the two.

## How it works

```
  ups.com (label page)
      │  1. a Tampermonkey userscript reads the page's own LabelRecovery
      │     request, switches it to labelFormat=zpl, downloads the ZPL,
      │     and "stages" it…                          ┌──────────────────────────┐
      └─────────────── POST /stage ─────────────────▶ │  local service :4349     │
                                                       │  (Python, LaunchAgent)   │
  You click "Print Thermal Label"                      │                          │
      │  2. UPS opens a hidden window that navigates   │  3. prints the staged    │
      └─────────────── GET /listPrinters ────────────▶ │     ZPL with `lp`        │
                                                       └────────────┬─────────────┘
                                                                    │ lp -d <printer>
                                                                    ▼
                                                             your thermal printer
```

Two pieces:

1. **`ups_print_bridge.py`** — a tiny local HTTP service on port `4349`
   (runs as a LaunchAgent, starts on login). It receives the ZPL and prints it
   with `lp`. It also answers the `/listPrinters` request UPS makes when you
   click *Print Thermal Label*.
2. **`userscript/ups-thermal-bridge.user.js`** — a Tampermonkey userscript that,
   on a label page, grabs the current label's ZPL from UPS's `LabelRecovery`
   API and stages it in the service. It also adds a **🖨️ Print to thermal
   printer** button.

The cross-origin call from `https://ups.com` to `http://127.0.0.1:4349` is made
with `GM_xmlhttpRequest`, which is not subject to mixed‑content / Private Network
Access blocking — that is why this works where a WebSocket‑based approach
(e.g. QZ Tray) gets blocked by Chrome.

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
git clone https://github.com/YOUR_GITHUB/ups-thermal-bridge-mac.git
cd ups-thermal-bridge-mac
./install.sh "YOUR_PRINTER_NAME"      # omit the name to use Bixolon_SRP770III
```

This copies the service to `~/Library/Application Support/UPSPrintBridge/`,
installs a LaunchAgent (`com.ups-print-bridge`) that starts on login, and runs
a smoke test. The script lives outside `~/Documents` on purpose — `launchd`
cannot read TCC‑protected folders.

### 3. Install the userscript

1. Install **Tampermonkey** in Chrome.
2. Tampermonkey → **Create a new script** → delete the template → paste the
   contents of [`userscript/ups-thermal-bridge.user.js`](userscript/ups-thermal-bridge.user.js) → **⌘S**.
3. (Edit the `@namespace` line if you like.)

---

## Usage

1. On ups.com, open the **label page** for your shipment (the URL looks like
   `https://www.ups.com/uel/llp/1Z...`).
2. Within ~2 seconds you'll see a green **"Label ready to print"** toast.
3. Either click **🖨️ Print to thermal printer** (the button this script adds),
   or click UPS's own **Print Thermal Label** — both print the current label.

One label per click; it always prints the label you're currently viewing.

## Known limitation: Shipping History → "Get Labels"

If you click **Get Labels** directly from the **Shipping History** list, UPS
sends the label straight to the (missing) native helper and **never loads it on
the page**, so there is nothing for the userscript to capture.

**Workaround:** from the history, **open the shipment's label page**
(`/uel/llp/...`) first, then print. On the label page capture is reliable.

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

- **No toast / button does nothing** → make sure Tampermonkey is enabled and the
  script is active on `ups.com`; open the console and look for `[UPS->Printer]`.
- **Prints the wrong/old label** → make sure you are on the label page (not the
  history list) and wait for the green toast before printing.
- **Blank label** → your CUPS queue is probably not *raw*; re-add it as Raw/Raw Queue.
- **`Failed to fetch` the very first time** → Chrome's Private Network Access
  warms up on the first request; just try again.

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
