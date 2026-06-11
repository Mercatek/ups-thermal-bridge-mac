# Privacy

Short version: **everything stays on your Mac.** This tool has no servers, no
accounts, and no telemetry.

## What data is involved

UPS shipping labels contain personal data (sender/recipient names and
addresses). This tool handles that label data only **in transit on your own
machine**, to get it from your browser to your printer.

## What the tool does and does not do

- ✅ Receives the label (ZPL) locally on `127.0.0.1:4349` and pipes it to your
  local printer via CUPS (`lp`).
- ✅ Keeps a local log at `~/Library/Logs/ups-print-bridge.log` for
  troubleshooting, and a copy of the **last** printed label at
  `~/Library/Logs/ups-last-label.zpl`. Both live only on your Mac; delete them
  anytime.
- ❌ Does **not** send any data to the developer or any third party.
- ❌ Has **no** analytics, tracking, crash reporting, or "phone home" of any kind.
- ❌ Makes **no** outbound network connections of its own. (Your browser talks to
  ups.com directly, as it always did; the tool only talks to your printer.)
- ❌ Stores **no** credentials — it never sees your UPS login.

## Settings stored

Only your chosen printer name and label format, in macOS `UserDefaults`
(standard app preferences). Nothing sensitive.

## GDPR / data protection

Because no personal data ever leaves your device and nothing is transmitted to
the developer or any processor, this tool does not act as a data controller or
processor on your behalf. You remain in full local control of the label data,
exactly as if you printed from a directly-connected printer.
