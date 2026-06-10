# Reverse-engineering the official "UPS Thermal Printing" app

Goal: understand the official local print helper UPS expects on
`http://127.0.0.1:4349`, so we can (a) judge whether a clean native macOS
re-implementation is feasible, and (b) ideally learn the exact protocol so the
**Shipping History "Get Labels"** flow can work without the Tampermonkey
userscript.

> Method: **static analysis only**. The Windows installer is never executed
> (it can't run on macOS, and running untrusted binaries is unsafe). Binaries
> are kept out of git (see `.gitignore`); only notes are committed.

## Source

- Official download (UPS CDN): `https://assets.ups.com/.../ups-thermal-printing-setup.exe`
- File: `ups-thermal-printing-setup.exe` — **12,212,800 bytes** (PE32, Windows GUI)
- SHA-256: `6906713e51b315cbebb374b9d0bd20131abbd3e52ffbea0fc92e63f61e14ba50`
- Mac guide (PDF) references a separate `UPS Thermal Printing-3.0.0.dmg`, plus
  Java applets / Safari NPAPI — i.e. the macOS build is Java-era and does not
  run on modern macOS / Apple Silicon. So the Windows installer is the most
  useful artifact to study.

## Installer structure (so far)

`ups-thermal-printing-setup.exe` is an **InstallShield self-extractor**:

- PE32 with 6 sections (`.text .rdata .data .didat .rsrc .reloc`); end of
  sections at offset `1,233,920`.
- A **10,978,880-byte overlay** is appended after the PE, starting with the
  magic **`ISSetupStream`** → InstallShield's embedded setup stream.
- Embedded files (names stored UTF-16LE in the stream):
  - locale strings: `0x0402.ini` … `0x0c0c.ini`, `Setup.ini`
  - **`UPS Thermal Printing.msi`** ← the real application payload (a Windows MSI)
- The embedded files are **compressed** with InstallShield's own scheme: a
  full-file scan finds **no** CFBF/MSI (`d0cf11e0`), zip/JAR (`PK`), cab
  (`MSCF`), or IS-cab (`ISc(`) signatures in the clear. So the MSI must be
  decompressed out of the stream before it can be inspected.

## Next steps

1. Parse the ISSetupStream file table → locate the `UPS Thermal Printing.msi`
   compressed block (offset + compressed/uncompressed sizes + method).
2. Decompress it (test zlib/deflate first).
3. Open the MSI (CFBF): read `File`/`Component`/`CustomAction` tables and the
   `Binary`/`Cabs` streams to recover the actual app files (native EXE? JRE +
   JARs?).
4. From the app files, recover the **`:4349` protocol**: the exact
   `/listPrinters` response shape and how the ZPL is delivered (esp. for the
   history flow).
5. Conclusions for a macOS re-implementation.

## What I actually did (and the shortcut that worked)

Defeating InstallShield's compressed/encrypted `ISSetupStream` on macOS with
only Python proved unnecessary: the **macOS build** is distributed as a plain
ZIP — `UPS_Thermal_Printing-3.0.0.zip` (link found inside UPS's own Mac guide
PDF, extracted from a FlateDecode stream). It contains
`UPS Thermal Printing-3.0.0.dmg` (a 2018 Java app), which mounts read-only and
is trivial to inspect:

- `UPS Thermal Printing.app/Contents/Java/ThermalApp_Test.jar` — the app
- `…/UPS Thermal Printing.cfg` — main class `com.ups.iss.printers.ThermalPrintController`
- `…/PlugIns/Java.runtime/…/jre` — a bundled **JRE 8 (x86)**

`www.ups.com` blocks non-browser clients (Akamai, `curl` → connection reset), so
the ZIP was fetched through the logged-in Chrome browser; `assets.ups.com` (CDN)
serves the `.exe` to `curl` fine.

The Java classes were decompiled by parsing their constant pools in Python.
The full protocol is written up in **[PROTOCOL.md](PROTOCOL.md)**; the verbatim
label-window page is saved as **`labelwindow_template.html`**.

## Conclusions for macOS

1. **The official macOS app is a dead end on modern macOS.** It's a 2018 Java/
   applet app with a bundled x86 JRE 8, unsigned, NPAPI-dependent. It will not
   run on Apple Silicon / current macOS. (This is why a re-implementation is
   needed at all.)

2. **The `:4349` protocol is fully known and re-implementable** (PROTOCOL.md):
   - `GET /listPrinters` → return an **HTML handshake page** (not JSON) with a
     printer `<select>` whose option value is the format code (`zpl` for a
     Zebra-class printer).
   - That page `postMessage`s the opener `{requestType:"request", labelType, …}`.
   - ups.com replies by `postMessage`-ing the **base64 label bytes** to the popup.
   - The popup `POST`s `printerName=…&labelBytes=<b64>` to `/print`.
   - `/print` Base64-decodes and prints; replies `status=…&target=HttpApp&…`.

3. **This unlocks the Shipping-History flow without the userscript.** Because the
   label bytes are delivered to the popup by `postMessage` from ups.com, it does
   not matter whether the user came from the label page or from history. Our
   bridge only failed the history flow because it returned JSON from
   `/listPrinters` instead of the handshake HTML, so ups.com never sent the
   label. Implementing the handshake fixes this.

4. **Plan:** add a "native handshake" mode to `ups_print_bridge.py` — serve the
   handshake HTML from `/listPrinters` (advertising the configured printer with
   `labelType=zpl`), keep `/print` accepting `printerName`/`labelBytes`
   (already supported). Then the Tampermonkey userscript becomes optional.
   This must be validated against live ups.com (the exact `postMessage` shape
   and `labelType` UPS expects can vary by page/region).

