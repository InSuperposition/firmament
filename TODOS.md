# TODOS

## Infrastructure

### Exclude two runs from one checkout around the k0sctl edge

**What:** Add a lock around the environment apply and destroy tasks so two runs from the same checkout cannot interleave.

**Why:** `claim_environment` refuses only a different worktree, and OpenTofu's state lock covers one command, not the render, `k0sctl apply` and publish sequence. An apply racing a destroy can remove the machine while `k0sctl` is mid-run.

**Context:** `claim_environment` in `.mise/lib.sh` writes the owning worktree to `$state/owner`. The repo has no lock pattern; macOS has no `flock`, so the work is a lock directory with stale-lock handling, taken by `env:apply`, `k0s:apply` and both destroy tasks.

**Effort:** M
**Priority:** P2
**Depends on:** orchestrator-k0sctl implementation

### Manage the GitHub repository settings as code

**What:** Declare branch protection, Actions permissions and package visibility in an OpenTofu root with the GitHub provider, so the settings that gate delivery are reviewed and recorded like the rest of the repository.

**Why:** Once Flux verifies artifacts signed by the publish workflow (engine-flux), the Git branch and the workflow's permissions are part of the trust root. A loosened branch rule or a broader token permission is visible only on GitHub's settings page and would pass every offline check.

**Context:** The plan's list of imperative edges has no row for repository settings. The stack has no GitHub provider and no token held for one, so start by deciding where that token lives (the secrets rule keeps it out of Git and OpenTofu state), then check what the provider can manage; package visibility is unverified.

**Effort:** M
**Priority:** P3
**Depends on:** engine-flux implementation

### Validate Flux manifests with flux-schema 0.15.0 directly

**What:** Pin `flux-schema` 0.15.0, call `flux-schema validate <dir> --envsubst-file .mise/flux-test-values.env --envsubst-strict --schema-location .mise/flux-schemas` from `flux:lint` and `flux:schemas`, then delete `render_flux_build` and `flux_test_values` from `.mise/lib.sh`.

**Why:** The `kubectl kustomize | flux envsubst | flux-schema` pipe in `lib.sh` is code the tool now covers itself. It is cleanup, not needed to deliver or verify the signed artifact.

**Context:** Check first that 0.15.0 leaves `${git_commit}` substituted and keeps any template marker intact.

**Effort:** S
**Priority:** P3
**Depends on:** engine-flux implementation

### Guard Flux artifact verification offline with CUE

**What:** A CUE schema in `flux:lint` that fails when the `OCIRepository` has no `spec.verify`, when its subject differs from the one derived from the repository and workflow file name, or when its URL differs from `artifact_source`.

**Why:** Catches a quietly dropped `spec.verify` before the cluster does. The chainsaw assertion in `env:verify` already proves verification on a live cluster, so this only adds an earlier, offline signal.

**Context:** Take the repository from `git remote get-url origin`; the subject is mixed case and `artifact_source` is lowercase.

**Effort:** S
**Priority:** P3
**Depends on:** engine-flux implementation

### Lint GitHub workflows with zizmor

**What:** Pin `zizmor` in `mise.toml` and add a `workflow:lint` task that runs it offline from `mise run check`.

**Why:** `publish.yaml` is the first workflow in the repository and holds `id-token: write`. A linter checks it for unpinned actions and risky triggers.

**Context:** `zizmor` may hit the mise SLSA signer rule when locking; see the `mise-2026-9-18-slsa-lock-regression` pitfall.

**Effort:** S
**Priority:** P3
**Depends on:** engine-flux implementation

### Verify OrbStack writes known_hosts on a fresh install

**What:** On a clean OrbStack profile, check that `~/.orbstack/ssh/known_hosts` holds `[127.0.0.1]:32222` keys before any machine exists.

**Why:** `modules/vm-orb` reads that file at plan time to output `ssh.host_keys`, and a postcondition fails apply when no key is found. On the author's Mac the file was created together with OrbStack's SSH key pair, long before any machine; a fresh install is unverified.

**Context:** The machine root reads the file with `file(pathexpand("~/.orbstack/ssh/known_hosts"))`; the postcondition error names the missing file. Start by installing OrbStack on a clean profile (or a second Mac), listing `~/.orbstack/ssh/` before creating a machine, then running `mise run env:e2e`.

**Effort:** S
**Priority:** P3
**Depends on:** machines-orbstack implementation
