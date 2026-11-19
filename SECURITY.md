# Security Policy

## Reporting a Vulnerability

Report privately through GitHub: **Security** tab → **Report a vulnerability** on
[penguinstark/tinycast](https://github.com/penguinstark/tinycast).

Include your macOS version, the Tinycast Sonoma version and channel, reproduction steps, and the
impact. Please don't disclose publicly until it's fixed.

## Supported Versions

The current build of this fork only. There is no released channel to update, so rebuild from
`xcode16-local` before reporting.

## Scope

Of particular interest:

- **Accessibility (TCC)** — anything that widens what the paste grant enables.
- **Clipboard history** — text and images cached on disk; unintended exposure or capture.
- **Network** — Tinycast is offline by default and every networked feature is consent-gated. A path
  that reaches the network without consent, or survives consent being withdrawn, is high severity.
- **Hotkeys** — the in-house hotkey stack and the Input Monitoring grant.
- **Signing and distribution** — anything that lets a build other than the one you signed run with
  your grants.

Out of scope: anything needing existing code execution or admin rights on the machine.
