# Changelog

Notable changes. Dates are release dates; the format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.1] — 2026-08-31

### Fixed

- A client that would not answer produced one sentence — `Cisco Secure Client did not answer` —
  for three different repairs: a VPN service that never came up, a call that ran out of time,
  and a reply this parse does not recognise. The client's own reply names which, and the menu
  was throwing it away, so a report of a silent client arrived with nothing in it to act on.
  The menu now quotes the client (`Cisco Secure Client said: …`) or blames the clock
  (`… did not answer within 12s`). Verbatim rather than classified on purpose: Cisco's healthy
  wording is not uniform — `LegacyLaunchDaemon(...): not registered` is the normal state on
  5.1.14 — so a classifier would be guessing, and would guess silently.
- `🕘 Session log` printed the logged event word as it stands, so a silent client showed as
  `Session log: unreadable at 13:51` — which names the log rather than the session and reads
  as a corrupt history. The log keeps the machine word, which is what makes it greppable; the
  menu now says `client silent`, `changing state` and `dropped`.

## [1.1.0] — 2026-08-30

### Added

- `⛔ Disconnect`, offered whenever there is a session to end. It needs no terminal window —
  ending a session asks Cisco for nothing — and the teardown is marked as one you asked for,
  so it raises no drop alert. Until now the menu could start a session but not end one.
- `🔕 Mute alerts for 1h`, and the `🔔 Resume alerts` that lifts it early. Silences the
  countdown warnings and the drop alert while the countdown itself keeps running. A mute is a
  deadline rather than a switch, so it always expires; `VPN_ETA_MUTE_MINUTES` sets the span,
  and `0` takes the item off the menu.

### Fixed

- `uninstall.sh` left the session history behind on every installation the README describes.
  SwiftBar names a plugin's data directory after the plugin file only while the plugin folder
  is SwiftBar's own, and after the plugin's full path once it is not — and only the first
  shape was on the list, so `--all` reported success over an untouched directory. Both shapes
  are removed now. The unscoped run had no test at all, which is what let the list go stale;
  it has one.
- The render that keeps a countdown alive off a still-bound tunnel offered no way to end that
  session, and told `🔑 Start new session…` to describe itself as if the VPN were down.

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
