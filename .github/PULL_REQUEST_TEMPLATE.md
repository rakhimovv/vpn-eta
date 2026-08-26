# What this changes

<!-- One or two sentences. If it fixes an issue, "Fixes #N". -->

# Why

<!-- What breaks or annoys without it. -->

# Checks

- [ ] `tests/vpn-eta.test.sh` passes
- [ ] `tests/install.test.sh` passes
- [ ] `shellcheck` is silent on every changed script
- [ ] New behaviour has a test
- [ ] A new setting is documented in **both** `config.example` and the README table
- [ ] `docs/make-menu-image.sh` re-run and `docs/menu.png` committed, if a menu line changed
- [ ] No real hostname, username or home path anywhere in the diff
