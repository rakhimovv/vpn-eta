# Changelog

Notable changes. Dates are release dates; the format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-08-25

First release. Previously a second SwiftBar plugin inside the `lidguard` repository, now its
own tool with an installer, a config file and tests.

### Added

- Menu-bar countdown for the Cisco Secure Client session limit, refreshed once a minute,
  green through orange to red as the deadline approaches.
- Notifications at 60 and 15 minutes left, each firing once per session, plus one if the
  tunnel drops on its own. A teardown you started yourself is not announced.
- `🔑 Start new session…`, which reconnects the configured profile in a terminal — Cisco
  asks for a password and usually a one-time code, and there is nowhere else to type them.
- Session log: one line per change of state, and a menu item that opens it.
- `install.sh`, which reads your saved profiles out of the client on your Mac, asks which to
  use, finds SwiftBar's plugin folder and writes `~/.config/vpn-eta/config` at mode `0600`.
  `--print-hosts`, `--host`, `--label`, `--terminal` and `--yes` for scripted runs.
- `uninstall.sh`, scoped by `--plugin-dir`, `--config` and `--state-dir`.
- Fourteen settings in a config file — the only place a setting reliably reaches the plugin,
  since SwiftBar starts plugins from launchd and never reads a shell profile. Includes
  `VPN_ETA_COMPACT` and an emoji-or-empty `VPN_ETA_LABEL` for a narrower menu-bar item.
- Support for more than one saved Cisco profile via `VPN_ETA_HOST`; with the choice ambiguous
  the plugin lists the profiles and prints the exact config line to add.
- Two gateways at once: a copy of the plugin under another filename reads its own
  `<name>.config`.
- Two test suites driving a fake Cisco client in a sandbox — no VPN, no SwiftBar, no network
  — plus CI and ShellCheck, and a menu screenshot generated from the plugin's own output.
