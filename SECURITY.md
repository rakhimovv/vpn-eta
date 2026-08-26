# Security

## Reporting a vulnerability

Use GitHub's [private vulnerability reporting](https://github.com/rakhimovv/vpn-eta/security/advisories/new).
It reaches the maintainer privately and keeps the details out of a public issue until there is a
fix. If the advisory form is unavailable to you, open an issue saying only that you have a security
report and asking for a private channel — no details in the issue itself.

This is a spare-time project with no SLA, but anything that could expose a credential, a
corporate hostname, or execute code from a file a user did not expect to be executable will
be looked at promptly.

**Do not include your real gateway hostname or username in the report.** A synthetic
reproduction is more useful anyway.

## What this tool does and does not touch

- **It never handles your VPN password.** There is no code path that reads, stores, prompts
  for or forwards one. Cisco's own client prompts you in the terminal SwiftBar opens; the
  secret never passes through this project. It deliberately does not use Cisco's `vpn -s`
  stdin-credential mode.
- **It runs no privileged commands.** No `sudo`, no setuid, no launch daemon.
- **It makes no network calls of its own.** The only thing that talks to your gateway is
  Cisco's client.
- **It writes to two places only:** the config file (`~/.config/vpn-eta/config`, mode
  `0600`) and its state directory. Never inside the repository.

## Things worth knowing

- **The config file is executed, not parsed.** It is sourced as a shell fragment, which is
  what makes `VPN_ETA_HOST='...'` work. Anything in it runs as you, once a minute. Treat it
  like `~/.zshrc`: it is yours, do not source someone else's. The installer single-quotes
  every value it writes, including profile names read from your Cisco client, so a profile
  name containing `$(...)` cannot become code.
- **A profile name is not a secret, but it is sensitive.** It identifies your employer's VPN
  gateway. The installer prints it to the console by design, and it lands in your config; be
  deliberate about where that output goes.
- **The session log records timings, never addresses.** `history.log` holds timestamps,
  state transitions and minutes remaining. The client IP is kept only in the state file used
  to tell one session from the next, and is not written to the log.
