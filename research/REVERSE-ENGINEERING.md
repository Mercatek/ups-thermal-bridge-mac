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

_(Findings are appended below as the analysis proceeds.)_
