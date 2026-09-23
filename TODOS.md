# TODOS

Abstract: Deferred work for firmament, ordered by priority within each
section. Each item carries enough context to pick up cold.

## Infrastructure

### Extract multi-line mise task shell into scripts

**What:** Move the multi-line `run` blocks in `mise.toml` into
`scripts/<verb-noun>.sh` files with a shared `scripts/lib.sh`.

**Why:** Every task that drives OpenTofu repeats the same state-directory
and `TF_VAR_*` lines (and `[env] KUBECONFIG` repeats the same path),
and shell embedded in TOML cannot be linted by shellcheck or tested by
bats.

**Context:** Tasks such as `plan`, `env:apply`, `env:destroy`,
`orb:*`, `ubuntu:verify` and `k0s:*` each compute
`dir="${FIRMAMENT_STATE_DIRECTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environment/local}"`
and export `TF_VAR_orbstack_ssh_key_path` and `TF_VAR_state_directory`.
`[env] KUBECONFIG` uses `get_env`, which keeps an empty
`XDG_STATE_HOME` or `FIRMAMENT_STATE_DIRECTORY` as empty, while the shell
tasks treat empty as unset; one definition removes that mismatch. When
`cilium status --wait` fails after apply, the script should also print
the k0s Chart status
(`kubectl -n kube-system get charts.helm.k0sproject.io -o yaml`), where
Helm install errors appear. Wait for the Chart to reconcile the new
spec before the pod checks: `cilium status` alone passes on the old pods
while k0s's asynchronous upgrade is pending or rolled back (seen live).
Compare the Chart's `.status.revision` before and after apply, and fail
on a non-empty `.status.error`.
Put that shared setup in `scripts/lib.sh`, give each task one script with
`#!/usr/bin/env bash` and `set -euo pipefail`, reference the scripts from
`mise.toml`, and add them to `check:shellcheck`, the `shfmt` checks and
bats. Keep one-line tasks inline.

**Effort:** M
**Priority:** P2
**Depends on:** None

### Add a live end-to-end test lane for the local environment

**What:** Add a `mise run local:e2e` task that runs a bats suite against a
real OrbStack machine: `env:destroy`, `env:apply`, the readiness
checks, `cilium:conformance`, then teardown again.

**Why:** The offline suites (`mise run check`) cover everything that can
be checked from a plan. They cannot catch regressions that only appear on
a live cluster, and those paths are currently checked by hand.

**Context:** Paths with no automated test today:

- the post-apply wait order in `env:apply` and `k0s:apply`
  (`cilium status --wait` must run before `kubectl wait`, because k0s
  restarts the API server after apply);
- `k0s:verify`, `cilium:verify` and `cilium:conformance`;
- `k0s:apply` and `k0s:plan` targeting
  `local_sensitive_file.kubeconfig`;
- a bootstrap with `TF_VAR_kube_proxy_replacement=false` (kube-proxy
  runs, Cilium uses veth with iptables masquerading);
- changing `kube_proxy_replacement` on a live cluster requires teardown
  and bootstrap;
- removing Cilium from `helm_charts` makes k0s uninstall it;
- changing one chart value and applying rolls the affected pods in
  place, without k0sctl resetting the cluster.
A full run takes about 15 minutes, so keep it out of `check` and the git
hooks. Run the scripts through `scripts/<verb-noun>.sh` with shellcheck,
not inline in `mise.toml`.

**Effort:** M
**Priority:** P2
**Depends on:** None

### Hand Cilium from the k0s Helm extension to Flux Operator

**What:** Move ownership of the Cilium Helm release from k0s
(`spec.extensions.helm`) to Flux Operator, so Flux manages Cilium
upgrades from Git.

**Why:** Cilium upgrades should flow through GitOps instead of k0s
cluster configuration changes.

**Context:** k0s installs Cilium through a `charts.helm.k0sproject.io`
Chart resource. Removing the chart from the k0s configuration makes k0s
uninstall the release, which removes the cluster network. The handoff
must first let Flux adopt the existing release (same release name and
namespace), then remove the chart from k0s without triggering the
uninstall. Start from the Flux Operator bootstrap module
(`controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes`), which
supports prerequisite charts with `flux_adoption_check`:
<https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap>
and <https://fluxcd.io/blog/2026/04/terraform-flux-operator-bootstrap/>.
Verify the adoption on a disposable local cluster before relying on it.

**Effort:** L
**Priority:** P3
**Depends on:** Cilium installed through `modules/cni-cilium` and the k0s
Helm extension.

## Completed
