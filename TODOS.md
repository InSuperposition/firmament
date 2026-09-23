# TODOS

Abstract: Deferred work for firmament, ordered by priority within each
section. Each item carries enough context to pick up cold.

## Infrastructure

### Extract multi-line mise task shell into scripts

**What:** Move the multi-line `run` blocks in `mise.toml` into
`scripts/<verb-noun>.sh` files with a shared `scripts/lib.sh`.

**Why:** Ten tasks repeat the same state-directory and `TF_VAR_*` lines,
and shell embedded in TOML cannot be linted by shellcheck or tested by
bats.

**Context:** Tasks such as `plan`, `bootstrap:local`, `teardown:local`,
`orb:*`, `ubuntu:check` and `k0s:*` each compute
`dir="${FIRMAMENT_STATE_DIRECTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environment/local}"`
and export `TF_VAR_orbstack_ssh_key_path` and `TF_VAR_state_directory`.
Put that shared setup in `scripts/lib.sh`, give each task one script with
`#!/usr/bin/env bash` and `set -euo pipefail`, reference the scripts from
`mise.toml`, and add them to `check:shellcheck`, the `shfmt` checks and
bats. Keep one-line tasks inline.

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
