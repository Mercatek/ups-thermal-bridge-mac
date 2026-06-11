# Release readiness — UPS Print Bridge (macOS app)

A pre-launch checklist, written honestly for **what this software actually is**:
a single-user **macOS menu-bar app** that runs an HTTP server bound to
`127.0.0.1:4349` and prints to a local CUPS queue. There is **no cloud server,
no database, no user accounts, no remote traffic**. So the classic cloud-SaaS
checklist (Docker, staging/prod, JMeter, Datadog, AWS Secrets Manager, GDPR data
processors) mostly does **not** apply. Below, each area is mapped to the
desktop-app reality, and what was actually done.

## 1. Infrastructure & deployment

| Cloud checklist | Reality here | Status |
|---|---|---|
| CI/CD pipeline | Build + (sign + notarize) + publish a DMG via GitHub Actions / Releases | ✅ CI added (`.github/workflows/build.yml`); notarization documented below |
| Identical staging/prod (Docker) | ❌ N/A — no server. The "environment" is the user's Mac. Docker is irrelevant. | N/A |
| Rollback strategy | Versioned GitHub Releases — a user can download/keep a previous version; the LaunchAgent/app can be replaced atomically | ✅ documented |

**Signing & notarization (the real macOS "deployment" gate):** the build is
ad-hoc signed, so first launch needs right-click → Open (Gatekeeper). For public
distribution you need an Apple Developer ID cert + `notarytool`. Not wired into
CI because it requires paid Apple credentials (kept out of the repo); steps are
documented in `SECURITY.md`.

## 2. Load & performance

| Cloud checklist | Reality here | Status |
|---|---|---|
| Stress test (JMeter/k6) | ❌ N/A as written — the server handles ~1 request per print click. BUT it's a threaded socket server, so concurrency safety matters. | ✅ ran a 200-request / 40-concurrent soak: 200/200 OK, server stayed up |
| DB / API latency | ❌ N/A — no database, no outbound API. Printing is a local `lp` pipe (sub-second). | N/A |

Added a print de-dup (SHA-1, 5 s window) and a lock so concurrent connections
can't race the print state.

## 3. Security & privacy

| Cloud checklist | Reality here | Status |
|---|---|---|
| SAST / code audit | Manual threat-model + review of the real attack surface (localhost server, CORS, command exec, input handling) | ✅ see `SECURITY.md` |
| Secret management | There are **no** secrets/keys/credentials in this app. Verified nothing sensitive is committed. | ✅ swept clean |
| Legal/GDPR | Labels contain personal data (names/addresses), but **everything stays on the machine** — no telemetry, no network egress except to your own printer. | ✅ see `PRIVACY.md` |

**Finding fixed before launch:** `/print` previously executed for *any* web
origin → any website you visited could print to your label printer. Now gated by
an origin allowlist (localhost / `*.ups.com` / no-Origin local tools); everything
else gets `403`. Verified with `evil.com` and `fake-ups.evil.com` → blocked.

## 4. Monitoring & maintenance

| Cloud checklist | Reality here | Status |
|---|---|---|
| Observability (Datadog/Prometheus) | ❌ N/A — you can't (and shouldn't) install agents on every user's Mac or phone home. The equivalent is a **local log**. | ✅ `~/Library/Logs/ups-print-bridge.log` |
| Early alerting | ❌ N/A — no ops team. The "alert" is the menu-bar UI showing a red/error state and the wizard surfacing failures to the user. | ✅ UI status |

## Bottom line

Genuinely launch-ready items done: security hardening (origin allowlist),
concurrency soak, secret/PII sweep, CI build, versioning/rollback via Releases,
local logging, privacy posture. The remaining real gate for *public* distribution
is **Apple notarization** (needs a paid Developer ID), which is the macOS analog
of "production deploy".
