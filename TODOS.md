# TODOS

## Infrastructure

### Exclude two runs from one checkout around the k0sctl edge

**What:** Add a lock around the environment apply and destroy tasks so two runs from the same checkout cannot interleave.

**Why:** `claim_environment` refuses only a different worktree, and OpenTofu's state lock covers one command, not the render, `k0sctl apply` and publish sequence. An apply racing a destroy can remove the machine while `k0sctl` is mid-run.

**Context:** `claim_environment` in `.mise/lib.sh` writes the owning worktree to `$state/owner`. The repo has no lock pattern; macOS has no `flock`, so the work is a lock directory with stale-lock handling, taken by `env:apply`, `k0s:apply` and both destroy tasks.

**Effort:** M
**Priority:** P2
**Depends on:** orchestrator-k0sctl implementation

### Verify OrbStack writes known_hosts on a fresh install

**What:** On a clean OrbStack profile, check that `~/.orbstack/ssh/known_hosts` holds `[127.0.0.1]:32222` keys before any machine exists.

**Why:** `modules/vm-orb` reads that file at plan time to output `ssh.host_keys`, and a postcondition fails apply when no key is found. On the author's Mac the file was created together with OrbStack's SSH key pair, long before any machine; a fresh install is unverified.

**Context:** The machine root reads the file with `file(pathexpand("~/.orbstack/ssh/known_hosts"))`; the postcondition error names the missing file. Start by installing OrbStack on a clean profile (or a second Mac), listing `~/.orbstack/ssh/` before creating a machine, then running `mise run env:e2e`.

**Effort:** S
**Priority:** P3
**Depends on:** machines-orbstack implementation
