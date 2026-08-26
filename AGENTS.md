# AGENTS.md

Notes for coding agents working on vpn-eta. `README.md` is the user manual and
`CONTRIBUTING.md` the house rules — read both; what follows is only what neither says
outright.

## The gate

```sh
tests/vpn-eta.test.sh      # the plugin: parsing, rendering, notifications, state
tests/install.test.sh      # install.sh and uninstall.sh — see the warning below
shellcheck install.sh uninstall.sh docs/make-menu-image.sh \
	swiftbar/vpn-eta.1m.sh tests/*.sh
```

Both suites green and ShellCheck silent, every time. CI runs exactly those plus `bash -n` /
`sh -n` over every script (`.github/workflows/tests.yml`). Neither suite needs a VPN,
SwiftBar or the network: both drive a fake Cisco client inside a `mktemp -d` sandbox. The
plugin suite takes about fifteen seconds.

⚠ **`tests/install.test.sh` quits and relaunches SwiftBar on the machine that runs it.**
`install.sh`'s `confirm()` treats "no terminal attached" as yes, so each of the six installer
runs reaches the restart step. Harmless on a CI runner, disruptive on the user's own Mac —
warn them first, or stub `osascript` and `open` onto `PATH` for the run.

**There is no single-test selector** — both suites are linear scripts. To exercise one case,
drive the plugin through the same seams the suite uses:

```sh
VPN_ETA_CONFIG=/dev/null VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          58 Minutes Remaining' swiftbar/vpn-eta.1m.sh
```

`VPN_ETA_CONFIG=/dev/null` is not optional there: without it your own config decides what you
are measuring.

## Layout

`swiftbar/vpn-eta.1m.sh` is the whole product — one bash file SwiftBar copies into its plugin
folder and re-runs every minute (that is the `1m` in the name). It must stay self-contained:
at runtime the repository is not there. `install.sh` and `uninstall.sh` (POSIX `sh`) only
place that file and manage `~/.config/vpn-eta/config`. Tests live in `tests/`, never beside
the plugin — SwiftBar runs every file in its plugin folder and chmods them executable itself.

Output is SwiftBar's menu format: **the first line is the menu-bar item**, `---` opens the
dropdown, and `| color= size= href= bash= param0= refresh=` are per-line parameters. Change a
menu line and `docs/menu.png` in the README is stale — regenerate it with
`docs/make-menu-image.sh` and commit the result.

## The invariant every render path serves

`off` appears only on positive evidence: a disconnect the client reported, or no `utun`
interface at all. `vpn stats` can exit 0 without ever reaching Cisco's daemon, and calling
that reply "disconnected" is the failure this plugin exists to avoid. Every branch is a rung
of one ladder, most confident first:

    client-reported countdown → extrapolated from cache → `on` / `…` → `?` → `off`

Extrapolation is fenced by three independent guards, each with its own tests: staleness
(`VPN_ETA_STALE_LIMIT`), the client address (a different one is a different session, so its
deadline says nothing), and — when the client is silent — whether that address is still
bound to a `utun`. A transition state (`Connecting` / `Reconnecting` / `Disconnecting`) carries the
deadline forward instead of clearing it; a Wi-Fi handover is not a session ending.

Touch a render branch and you owe both directions a check. The suite pairs them deliberately:
an ambiguous read must never claim `off`, and a real disconnect must still be announced —
including the common one that leaves through `Reconnecting`.

## State, and the catch that protects it

Four files under `STATE_DIR`: `last-session` (cached countdown, client address, marks already
notified), `last-event` (the dedupe key that makes a per-minute plugin log one line per
*change*), `history.log`, and `expected-teardown` (a disconnect the plugin itself started must
not raise an alarm).

`may_write_state()` is the safety catch: a run with `VPN_ETA_TEST_STATS` set writes no state
and sends no notification, so hand-testing cannot disturb a live session's bookkeeping or
interrupt whoever is at the keyboard. The suite opts back in with `VPN_ETA_TEST_PERSIST=1`
only after pointing `SWIFTBAR_PLUGIN_DATA_PATH` at a temp directory. Never lift that catch to
make a test pass.

## Test seams

| Variable | What it substitutes |
|---|---|
| `VPN_ETA_TEST_STATS` | the client's `stats` output, verbatim |
| `VPN_ETA_TEST_RC` | that call's exit status |
| `VPN_ETA_TEST_PERSIST` | opts a fixture run back into writing state |
| `VPN_ETA_VPN_BIN` | a fake Cisco binary — the only way to test the start path |
| `VPN_ETA_NOTIFY_SINK` | collects notifications in a file instead of delivering them |
| `VPN_ETA_CONFIG` | the config file to source (`/dev/null` for documented defaults) |

## Adding a setting

`CONTRIBUTING.md` names the four places (plugin, `config.example`, README table, a test). Two
things it leaves out: numeric settings go through `number_or`, so a hand-typo degrades to the
default rather than spraying a shell error into the middle of the menu; and installer-written
values go through `shquote()` — the config is a shell fragment the plugin **sources every
minute**, so a profile name containing `$(...)` is not a formatting problem but execution.
There is a test holding that line.

Settings reach the plugin only through that file. SwiftBar starts plugins from launchd, which
reads no shell profile, so an exported variable reaches a terminal run and never the menu bar.
The same limitation is why a second copy of the plugin finds its config by its own filename —
there is nowhere to set a per-plugin environment variable.
