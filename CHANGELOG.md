# Changelog

Notable changes. Dates are release dates; the format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.6.1] — 2026-09-30

### Fixed

- The menu bar fell behind Cisco whenever Cisco's daemon stopped answering, which
  it does while it tears a tunnel down or brings one back. A dropped tunnel kept
  showing as connected for about 20 seconds, and after a Disconnect click the bar
  went on showing Reconnecting for several seconds, long enough to invite a
  second click. A call that runs out of time is no longer retried. The bar shows
  what is already known, and SwiftBar reads again a few seconds later.
- The CLI watchdog now also kills a call that ignores TERM. While the daemon was
  gone, such calls ran 88 and 101 seconds past their 12-second limit.
- A Disconnect click refreshes the menu bar at once and draws `disconnecting…`
  until Cisco confirms.
- A call that times out during a reconnect keeps the reconnect on the bar
  instead of switching to "unknown".

### Changed

- `VPN_ETA_TIMEOUT` defaults to 5 seconds (was 12). A healthy call takes about
  one.

## [1.6.0] — 2026-09-28

### Added

- `VPN_ETA_HOST_FALLBACK`: a second gateway that automatic reconnection tries
  when the first refuses the session. If a one-time code was already spent on
  the first, it waits for the next code before trying the second.
- Diagnostics for automatic sign-in. `auto-transcript` keeps what Cisco
  printed during the latest attempt, with what was typed and any long run of
  digits redacted before it is written. Each attempt adds an `auto` line to
  `history.log` naming the gateway, the result, the last stage reached and
  the time taken. With `VPN_ETA_INCIDENT_LOG=1`, a failed sign-in saves an
  incident of its own, with the attempt's stages and transcript appended.
- `connected` lines in `history.log` name the gateway server that holds the
  session.
- `VPN_ETA_AUTO_TIMEOUT` sets how long one automatic sign-in may wait for a
  recognised answer (45 seconds, as before).

### Fixed

- A gateway that refused the session after sign-in ("No assigned address",
  "rejected the connection attempt", "Could not connect to server") was not
  recognised: the attempt waited out its 45 seconds, and then paused automatic
  reconnection as a timeout. It is now recognised at once, and it retries
  every `VPN_ETA_AUTO_RETRY` seconds with one notification per outage.
  Credential failures still pause.

## [1.5.1] — 2026-09-27

### Fixed

- The connected and disconnected shields follow the menu bar's own tint, as
  Wi-Fi does, instead of a light/dark pair that could draw white on a light
  menu bar. Disconnected is the same shield, faded.
- After a reconnect the shield could fall back to amber for up to a minute:
  the run that saved an incident log finished after the run that saw the
  session return. The capture now runs in the background.

## [1.5.0] — 2026-09-25

### Changed

- The shield's colour now follows the connection's state only. A confirmed
  session stays neutral however little time is left; amber means the
  connection is changing or unconfirmed, and red means it is stuck, sign-in is
  delayed, or Cisco is missing. `VPN_ETA_CRITICAL_MINUTES` and
  `VPN_ETA_WARN_MINUTES` are gone, and the 60/15 notifications are unchanged.
- The connected menu leads with `Connected`, then the remaining time. When
  Cisco reports the session expiring and automatic reconnection is on, the
  menu says it will sign in again.

### Fixed

- When a session expired, the last countdown (`1m`) stayed on the bar for as
  long as the automatic sign-in took. The scheduled sign-in now runs in the
  background: the bar switches to `connecting…` straight away and refreshes as
  soon as Cisco answers.

## [1.4.0] — 2026-09-24

### Added

- The menu bar now shows a small outline shield whose colour distinguishes
  connected, changing, disconnected, unreadable and urgent states. The precise
  countdown remains in the menu. `VPN_ETA_BAR_MODE=countdown` restores the
  former text display and honours `VPN_ETA_LABEL` and `VPN_ETA_COMPACT`.
- A macOS network-state watcher asks SwiftBar for a fresh Cisco reading after
  interface changes. The existing one-minute refresh remains for client changes
  that do not affect a network interface.

## [1.3.2] — 2026-09-24

### Added

- Automatic sign-in now announces when it starts and when Cisco reports a
  connection. While it runs, the menu bar shows `VPN connecting…` and the menu
  shows its latest recorded stage and elapsed time. After 75 seconds without a
  result, the bar says `login delayed…`; an orphaned marker expires after five
  minutes instead of looking active forever. Progress remains visible while
  Cisco's `stats` reply is unreadable during sign-in.

## [1.3.1] — 2026-09-24

### Fixed

- Cisco can print `Disconnected` while starting a new connection, before asking
  for credentials. Automatic login now continues through that initial state.
- The menu offers a direct Keychain login when Cisco confirms a disconnect,
  alongside the separate manual SMS/TOTP path. Failed attempts record a
  credential-free stage trace and show the pause reason in the menu.
- A controlled live renewal on macOS with Cisco Secure Client 5.1.14.145
  reached a new session after reading both Keychain items.

## [1.3.0] — 2026-09-24

### Added

- Optional automatic reconnection after Cisco explicitly reports `Disconnected`.
  The plugin reads a VPN token PIN and TOTP key from macOS Keychain when Cisco
  asks for a password, and generates the current code then. Repeated attempts
  are spaced at least five minutes apart. A failed login or manual Disconnect
  pauses automatic reconnection until it is resumed from the menu.
- `VPN_ETA_KEYCHAIN_SERVICE` gives a second plugin copy its own PIN and TOTP
  items when another gateway uses a different token.
- Keychain reads and the Cisco prompt sequence are time-bounded so a blocked
  credential request cannot leave a SwiftBar refresh waiting indefinitely.
- Informational menu rows no longer behave like clickable actions in SwiftBar.
- Uninstall now reads a configured state directory before removing the config
  that names it.

## [1.2.0] — 2026-09-01

### Added

- `VPN_ETA_TRANSITION_LIMIT` (default `5` minutes). A reconnect that outlives any plausible
  Wi-Fi handover is a tunnel that is stuck rather than one that is settling: past this the menu
  bar turns red, the menu says `Reconnecting for 12m — the tunnel may be stuck` in place of the
  line about where the number came from, and one notification carries it off the screen nobody is
  looking at. It fires once per transition, respects the mute, and stays quiet for a teardown you
  started yourself. `0` switches the escalation off. The clock is the transition's own — kept in
  the state file that already dedupes the log, so a Mac waking from a long sleep into an ordinary
  handover starts it fresh instead of alarming on the age of the reading it slept through.

- `VPN_ETA_INCIDENT_LOG` (off by default) and `VPN_ETA_INCIDENT_KEEP` (default `20`). With the
  first on, a reconnect, a drop or an unreadable reply saves the Cisco client's own log for the
  previous fifteen minutes into `incidents/` beside `history.log`. The history line says the
  tunnel changed state; only the client's log says which gateway address a reconnect was retrying,
  and macOS ages the client's messages out within hours — measured on one Mac, a query over one
  midday window returned hundreds of lines at 19:00 and a single line by 23:00, while other
  processes' messages from that identical minute were untouched. Bounded by count and not by age,
  so the directory has a ceiling rather than a growth rate.

### Changed

- Cisco qualifies its `Connection State` in parentheses — `Reconnecting (waiting for network
  connectivity)`, `Connected (session expiring soon)` — and every branch compared the whole field,
  so those readings matched no arm and fell through to the disconnect path. A live session
  rendered as a gray `off` with a drop notification behind it: on the Mac this was found on, 12 of
  the 20 disconnects the plugin had ever recorded were this, 6 of them on a state the client
  spelled `Connected`. Comparisons now read the state word; the menu and the history keep the
  whole field, which is the half that says something.

- A carried deadline is now marked in the menu bar: `6h 20m…` in orange while the client reports
  Connecting, Reconnecting or Disconnecting, rather than the same green `6h 20m` a confirmed
  reading gets. Carrying the deadline across a reconnect stays right — the gateway's clock does
  not pause for one — but drawing it as confirmed left the menu bar looking healthy over a tunnel
  passing no traffic, with the word `Reconnecting` a click away in a dropdown nobody had opened.

## [1.1.2] — 2026-08-31

### Added

- A second README picture, of the menu when the client will not answer — the state the
  troubleshooting entry is about, which until now was described but never shown. Both pictures
  come out of `docs/make-menu-image.sh`, which runs the plugin and draws its real output.
- `VPN_ETA_TEST_IFCONFIG`, substituting the `ifconfig` reading that both tunnel probes parse.

### Fixed

- The suite could only **skip** the extrapolation case — the branch this plugin exists for — when
  the machine running it had no `utun`, which is every CI runner; and the opposite direction, no
  tunnel at all, could not be tested on a developer's machine that had one. Both now run
  everywhere, against a fixed `ifconfig` fixture, and a third arm covers a tunnel holding a
  *different* address. The parsing stays the code under test: the seam substitutes the reading,
  not the verdict.
- `docs/make-menu-image.sh` claimed a fixed timestamp made re-runs byte-identical. It does fix the
  content, but Chrome's PNG encoder varies a few bytes across versions on identical input, so a
  `git status` hit there is not evidence the picture changed. The comment now says which to check.

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
