# UPS Thermal Label Bridge for macOS — Non-ZPL Printer Support

Print **UPS thermal (ZPL) shipping labels** straight from **ups.com** to a
label printer on **macOS** — without the official "UPS Thermal Printing" app
(which is Windows-only in practice / a dead Java-era app on modern macOS).

This is a fork of [Mercatek/ups-thermal-bridge-mac](https://github.com/Mercatek/ups-thermal-bridge-mac),
which targets **Zebra-class printers that speak ZPL natively** (Zebra,
Bixolon, Eltron) via a raw CUPS queue. This fork is for everyone else —
printers like the **Brother QL series** that use their own raster protocol
and have no ZPL interpreter at all, so raw ZPL passthrough doesn't work no
matter how the CUPS queue is configured.

> Not affiliated with or endorsed by UPS. Use at your own risk.

---

## Does this solve your problem?

This is for you if, on a **Mac**, with a **non-Zebra label printer** (Brother
QL series, or anything else that doesn't speak ZPL natively):

- Clicking **"Print Thermal Label"** on **ups.com** does nothing, or opens an empty/blank window.
- The official **UPS Thermal Printing** app is Windows-only, or won't run on modern macOS.
- UPS expects a local helper on **`127.0.0.1:4349`** that doesn't exist on your Mac.
- You tried the [upstream project](https://github.com/Mercatek/ups-thermal-bridge-mac) and printed garbage, because your printer doesn't understand ZPL at all.

If you have a **Zebra/Bixolon/Eltron** printer that already speaks ZPL, use
the upstream project instead — it prints directly via a raw CUPS queue with
no rendering step, which is simpler when it applies.

---

## How it's different from upstream

Upstream pipes raw ZPL bytes straight to a CUPS *raw* queue, which only works
if the printer's firmware understands ZPL. A Brother QL has no ZPL
interpreter — it needs its own raster protocol, and just doesn't understand
what raw ZPL bytes mean.

This fork keeps upstream's hard part completely untouched: the
reverse-engineered protocol that gets ups.com to hand over the label's real
ZPL bytes to a local service. It only changes what happens *after* those
bytes arrive:

```
  ups.com  ──── (same handshake as upstream, unmodified) ───▶  local service :4349
                                                                     │
                                                     labelize renders ZPL -> PNG
                                                     (offline, no third-party service)
                                                                     │
                                                          opens in Preview.app
                                                                     │
                                                    you print it yourself (Cmd+P)
```

Two things changed after the render step vs. earlier revisions of this fork,
worth knowing if you're adapting this for your own printer:

- **Render density matters, and it's not the printer's resolution.** ZPL
  coordinates are dot numbers with no inherent physical size — they're
  authored assuming a density, almost universally **8 dots/mm (203dpi)**,
  regardless of what printer eventually renders them. Rendering at your
  printer's *actual* resolution (e.g. 300dpi) silently shrinks everything
  toward the top-left of the requested canvas instead of filling it.
- **Real UPS ZPL often includes `^POI`** (Print Orientation: Inverted) — a
  Zebra-specific mechanical compensation for how labels feed through *that*
  printer class. It has no meaning once you're rendering to an image instead
  of feeding a Zebra engine directly, and left in place it renders the whole
  label upside-down. This fork strips it (forces `^PON`) before every render.

**Printing is deliberately manual, not automatic.** Earlier iterations tried
a custom confirm dialog, then tried scripting Preview's own `print` command
to reuse the native print sheet. The second approach seemed clever but
turned out to silently submit to whatever printer Preview had last used,
with no dialog and no way to tell it happened — worse than no automation.
What's here now just opens the rendered label in Preview.app and stops.
Printing — picking the printer, paper size, hitting Print — is entirely
manual from there, the same as printing any other image.

---

## Requirements

- macOS with **Python 3** (`python3 --version`; install via `xcode-select --install` if missing).
- [`labelize`](https://github.com/GOODBOY008/labelize) — offline ZPL/EPL renderer:
  ```bash
  brew tap GOODBOY008/homebrew-labelize && brew install labelize
  ```
- Your printer already installed as a normal CUPS/AirPrint queue (no special
  "raw queue" setup needed — unlike upstream, since nothing here talks ZPL to
  the printer directly).
- **Google Chrome** (recommended) with the **Tampermonkey** extension (optional, see below).

## Install

```bash
git clone https://github.com/voltechs/ups-thermal-bridge-mac.git
cd ups-thermal-bridge-mac
./install.sh "YOUR_PRINTER_QUEUE_NAME"   # omit the name to use Brother_QL_1110NWB
```

Find your printer's CUPS queue name with `lpstat -p`. This copies the
service to `~/Library/Application Support/UPSPrintBridge/`, installs a
LaunchAgent (`com.ups-print-bridge`) that starts on login, and runs a smoke
test. The script lives outside `~/Documents` on purpose — `launchd` cannot
read TCC-protected folders.

### (Optional) Install the userscript

Not required — the print flow works with just the service. Install it only
if you want the floating **🖨️ Print to thermal printer** button on label
pages:

1. Install **Tampermonkey** in Chrome.
2. Tampermonkey → **Create a new script** → delete the template → paste the
   contents of [`userscript/ups-thermal-bridge.user.js`](userscript/ups-thermal-bridge.user.js) → **⌘S**.

---

## Usage

Click **Print Thermal Label** on ups.com — from a label page **or** from
**Shipping History → "Get Labels"**. A small window flashes open
("Rendering the label… → Opened in Preview -- print it from there.") and
closes itself. Preview.app opens showing the rendered label. Print it from
there with **⌘P**, the same as any other image.

It always fetches the label for the shipment you just chose (never a stale
one), and won't reopen the same label twice in a row from overlapping
requests.

## Configuration

Environment variables, set in the LaunchAgent's plist (re-run `./install.sh
"Printer_Name"` to regenerate it, or edit `~/Library/LaunchAgents/com.ups-print-bridge.plist` directly):

| Variable | Default | Meaning |
|---|---|---|
| `UPS_BRIDGE_PRINTER` | `Brother_QL_1110NWB` | Printer name advertised to ups.com's handshake JS. Cosmetic only -- nothing here calls `lp`. |
| `UPS_BRIDGE_PORT` | `4349` | Port to listen on |
| `UPS_BRIDGE_HOST` | `127.0.0.1` | Interface |
| `UPS_BRIDGE_LABEL_WIDTH_MM` | `103` | Label width passed to `labelize` |
| `UPS_BRIDGE_LABEL_HEIGHT_MM` | `164` | Label height passed to `labelize` |
| `UPS_BRIDGE_LABEL_DPMM` | `8` | Render density -- see "How it's different from upstream" above before changing this |
| `UPS_BRIDGE_LABELIZE_BIN` | auto-detected | Path to the `labelize` binary |

Adjust `LABEL_WIDTH_MM`/`LABEL_HEIGHT_MM` to match your actual label stock
(check what your printer reports as loaded — e.g. a Brother DK-1241 label is
103×164mm, not the generic "4×6" you might assume).

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

# The last ZPL actually received from UPS (for inspection/re-rendering)
cat ~/Library/Logs/ups-last-label.zpl

# The last rendered label (persists after the Preview window is closed)
open ~/Library/Logs/ups-last-label.png
```

- **Content only fills part of the label, rest is blank** → check
  `UPS_BRIDGE_LABEL_DPMM` -- it almost certainly needs to be `8`, not your
  printer's native resolution.
- **Content is garbled or appears rotated near one edge** → the `^POI`
  stripping should already handle this; if it's still happening, check
  `~/Library/Logs/ups-last-label.zpl` for a `^PO` command this fork's regex
  didn't catch, and open an issue with the specific ZPL.
- **Window says "No label received from UPS"** → that shipment's label
  wasn't delivered; open its label page (`/uel/llp/...`) and try again.
  Watch the log for `handshake_loaded` / `label_received`.
- **`Failed to fetch` the very first time** → Chrome's Private Network
  Access warms up on the first request; just try again.

## Uninstall

```bash
./uninstall.sh
```

…and remove the userscript in Tampermonkey if installed.

## Credit

The hard part -- reverse-engineering the `127.0.0.1:4349` handshake protocol
that gets ups.com to hand over a shipment's real ZPL -- is
[Mercatek](https://github.com/Mercatek)'s work, not this fork's. See
[`research/`](research/) for the full protocol writeup. This fork only
changes what happens after the ZPL bytes arrive.

## Disclaimer

This is an unofficial, community tool. It does not modify UPS data; it only
re-requests the label your account is already allowed to view. Trademarks
belong to their owners.
