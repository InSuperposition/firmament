# TODOS

## Infrastructure

### Verify OrbStack writes known_hosts on a fresh install

**What:** On a clean OrbStack profile, check that `~/.orbstack/ssh/known_hosts` holds `[127.0.0.1]:32222` keys before any machine exists.

**Why:** `modules/vm-orb` reads that file at plan time to output `ssh.host_keys`, and a postcondition fails apply when no key is found. On the author's Mac the file was created together with OrbStack's SSH key pair, long before any machine; a fresh install is unverified.

**Context:** The machine root reads the file with `file(pathexpand("~/.orbstack/ssh/known_hosts"))`; the postcondition error names the missing file. Start by installing OrbStack on a clean profile (or a second Mac), listing `~/.orbstack/ssh/` before creating a machine, then running `mise run env:e2e`.

**Effort:** S
**Priority:** P3
**Depends on:** machines-orbstack implementation
