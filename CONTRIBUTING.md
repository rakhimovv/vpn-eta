# Contributing

Issues and pull requests are welcome. It is a small tool; nothing here is heavyweight.

## Before you open an issue

**Redact your gateway.** The one thing this project asks of you. `./install.sh --print-hosts`,
the installer's progress output, the plugin's `Start new session` output and your config file
all contain your employer's real VPN hostname, and often your home directory. Replace them
with `vpn.example.com` and `/Users/you` before pasting anything.

Useful to include: your macOS version, `defaults read /Applications/SwiftBar.app/Contents/Info.plist CFBundleShortVersionString`,
your Cisco client version, and what the menu bar showed versus what you expected.

## Running the tests

No VPN, no SwiftBar and no network needed — both suites drive a fake Cisco client inside a
temporary directory.

```sh
tests/vpn-eta.test.sh      # the plugin: parsing, rendering, notifications, state
tests/install.test.sh      # install.sh and uninstall.sh
shellcheck install.sh uninstall.sh docs/make-menu-image.sh \
	swiftbar/vpn-eta.1m.sh tests/*.sh
```

CI runs exactly those on every push. Both must be green and ShellCheck must be silent.

CI's ShellCheck is whatever the Ubuntu runner ships, which lags Homebrew's — the first CI run
of this repo failed on an `SC2015` that the newer local version no longer reports. If CI
flags something you cannot reproduce, that is usually why; write the unambiguous form rather
than adding a `disable` for it.

**Tests may never touch a real installation.** `tests/install.test.sh` exists in the shape it
does because an earlier `uninstall.sh` ignored `--plugin-dir` and deleted a live session
history during an audit. Anything that removes files must be scoped by an argument and must
have a test proving it cannot reach past that scope.

## House style

- POSIX `sh` for `install.sh`, `uninstall.sh` and `docs/make-menu-image.sh`; `bash` for the
  plugin and the suites. macOS ships bash 3.2 — no `local -n`, no associative arrays.
- Tabs for indentation, matching the existing files.
- Comments explain **why**, not what. If a line looks odd and is deliberate, say what breaks
  without it — several here record a real failure.
- New behaviour comes with a test. New settings are documented in `config.example` *and* the
  README table, and read through the same `${VPN_ETA_X:-default}` pattern as the rest.

## Changing the menu

`docs/menu.png` in the README is generated from the plugin's real output:

```sh
docs/make-menu-image.sh
```

Run it when you change a menu line, and commit the result — that is what keeps the picture
honest.

## Scope

This reads Cisco Secure Client's own CLI. Support for other VPN clients is out of scope: the
parsing, the session model and the reconnect handling are all Cisco-shaped, and a second
client would be a different tool rather than a flag.
