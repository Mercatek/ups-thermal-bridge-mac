# Security

This tool runs a small HTTP server on your own machine to bridge ups.com to your
local thermal printer. This document is the threat model and the hardening done.

## Trust boundary

- The server binds to **`127.0.0.1` only** (loopback). It is **not reachable
  from the network/LAN** — only software on your Mac (and your browser) can reach it.
- It runs as **your user**, not root.
- It executes exactly one external command: **`/usr/bin/lp -d <queue>`**, with
  the label bytes piped to **stdin** (never interpolated into a shell). So label
  content cannot inject shell commands.
- The target printer queue comes from **your saved configuration**, never from a
  network request — a web page cannot redirect printing to an arbitrary
  destination.

## What an attacker on a web page could try

Because any web page in your browser can send requests to `127.0.0.1:4349`, the
realistic risk is a malicious site POSTing ZPL to `/print` to **spam your label
printer** or send ZPL configuration commands.

**Mitigation (implemented):** the side-effectful `/print` action is gated by an
**origin allowlist** — it only runs when the `Origin` is:

- the local handshake page (`http://127.0.0.1:4349`),
- `ups.com` / `*.ups.com`, or
- absent (local CLI tools / the userscript's privileged request).

Any other origin (e.g. `https://evil.com`, or look-alikes like
`https://fake-ups.evil.com`) receives **HTTP 403** and nothing is printed.
Verified by test. Read-only endpoints (`/ping`, `/listPrinters` JSON) are
harmless and remain open for compatibility.

Residual, low-severity: a local process or an allowlisted page could still queue
labels; de-dup (SHA-1, 5 s) limits accidental duplicates. This matches the
behaviour of the official UPS helper, which also trusted localhost callers.

## Secrets & data

- The app stores **no passwords, API keys, tokens or certificates**. It needs none.
- It makes **no outbound network connections** of its own (your browser talks to
  ups.com; the app only talks to your printer via CUPS).
- See [PRIVACY.md](PRIVACY.md) for data handling.

## Code signing & notarization (for distributors)

Builds here are **ad-hoc signed**, so the first launch needs
right-click → **Open** (Gatekeeper). To distribute publicly without that prompt:

1. Sign with a **Developer ID Application** certificate:
   `codesign --force --options runtime --deep -s "Developer ID Application: …" "UPS Print Bridge.app"`
2. Notarize: `xcrun notarytool submit <zip> --apple-id … --team-id … --wait`
3. Staple: `xcrun stapler staple "UPS Print Bridge.app"`

These require a paid Apple Developer account; credentials must **not** be
committed — pass them via CI secrets.

## Reporting

Found an issue? Open a GitHub issue (omit any sensitive details) or contact the
maintainer.
