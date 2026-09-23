# TODOS

Abstract: Deferred work for firmament, ordered by priority within each
section. Each item carries enough context to pick up cold.

## Infrastructure

### Run the offline checks in CI

**What:** Add a GitHub Actions workflow that runs `mise run check` on
every pull request and on pushes to `main`.

**Why:** The only gate today is the local pre-push hook. It runs only in
clones where `mise install` installed it, can be skipped with
`--no-verify` or `HK=0`, and checks only the first ref in a multi-ref
push. A merge can therefore land code that fails `mise run check`.

**Context:** Keep the workflow declarative: one job that installs the
pinned tools with `jdx/mise-action` (pinned by commit SHA, using
`mise.lock` through `MISE_LOCKED_SCOPES=project mise install --locked`)
and runs the one-line step `mise run check`, with no other shell in the
YAML. Confirm first that every suite runs offline on a Linux runner:
- the vm-orb suite asserts that planning makes no OrbStack calls, but the
  OrbStack provider must still install on Linux;
- the os-ubuntu SSH fixture must work there;
- `tasks:test` resolves config with the real `mise`.
Cache `~/.cache/firmament/tofu-plugins` (the shared `TF_PLUGIN_CACHE_DIR`)
and the mise install directory. GitHub had intermittent outages when this
was written, so make the check required only after it has run reliably.

**Effort:** S
**Priority:** P2
**Depends on:** None

### Add a live end-to-end test lane for an environment

**What:** Add an `env:e2e [environment]` file task
(`.mise/tasks/env/e2e.sh`) that runs a suite against a real OrbStack
machine: `env:destroy -y`, `env:apply`, `verify`, `cilium:conformance`,
then `env:destroy -y` again.

**Why:** The offline suites (`mise run check`) cover everything that can
be checked from a plan. They cannot catch regressions that only appear on
a live cluster, and those paths are currently checked by hand.

**Context:** Paths with no automated test today:

- the post-apply wait in `env:apply` and `k0s:apply` against a real
  cluster (the order and the chart states are unit-tested with stubs in
  `.mise/tests/lib.bats`);
- `k0s:verify`, `cilium:verify`, `ubuntu:verify` and
  `cilium:conformance`;
- `k0s:apply` and `k0s:plan` targeting
  `local_sensitive_file.kubeconfig`;
- a bootstrap with `TF_VAR_kube_proxy_replacement=false` (kube-proxy
  runs, Cilium uses veth with iptables masquerading);
- changing `kube_proxy_replacement` on a live cluster requires teardown
  and bootstrap;
- removing Cilium from `helm_charts` makes k0s uninstall it;
- changing one chart value and applying rolls the affected pods in
  place, without k0sctl resetting the cluster.

A full run takes about 15 minutes, so keep it out of `check`, the `test`
aggregate and the Git hooks. Name it `e2e`, not `test`, so the `*:test`
wildcard never selects it. Decide between bats and chainsaw (below)
before writing it.

**Effort:** M
**Priority:** P2
**Depends on:** The chainsaw evaluation below.

### Adopt chainsaw for live cluster tests

**What:** Plan how [chainsaw](https://github.com/kyverno/chainsaw)
(Kyverno's declarative Kubernetes end-to-end test tool) fits the live
test verbs: `verify` (read-only assertions on a running cluster),
`conformance` and `e2e`.

**Why:** Live checks are currently imperative shell (`kubectl wait`,
`cilium status`). Chainsaw expresses them as YAML assertions on resource
state, with built-in retries, timeouts and cleanup, which suits the
end-to-end lane above.

**Context:** Decide which layer owns what: chainsaw for Kubernetes
resource assertions, the `cilium` CLI for Cilium's own connectivity
suite, and mise file tasks as the entry points (`env:e2e`,
`*:verify`). Pin chainsaw through mise `[tools]`, and keep its suites out of the
`test` aggregate, since they need a live cluster. Needs its own
planning before any code.
<https://kyverno.github.io/chainsaw/>

**Effort:** M
**Priority:** P2
**Depends on:** None

### Evaluate `tofu test` for the plan-level module suites

**What:** Plan a move of the module suites (`modules/*/tests/unit.bats`)
and the wiring suite (`environment/local/tests/integration.bats`) from
bats + jq + yq to OpenTofu's native `tofu test` (`*.tftest.hcl` with
`command = plan` and `mock_provider`).

**Why:** The suites assert on plans, which `tofu test` does
declaratively, without the shell that renders a plan and digs through
its JSON.

**Context:** cni-cilium and orch-k0s assert on rendered values and
variable validation, and look like direct fits. os-ubuntu runs its
probe through an SSH fixture on PATH, and vm-orb asserts that planning
makes no OrbStack calls. Both may need to stay on bats, or need mocks
that `tofu test` may not support. Check how `tofu test` would run under
the `test` aggregate and the hk pre-push gate, and whether `hk`'s `tofu`
builtin covers `*.tftest.hcl` formatting (it globs it already). Needs
its own planning before any code.
<https://opentofu.org/docs/cli/commands/test/>

**Effort:** M
**Priority:** P3
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

### Add a second environment

**What:** Add a second `environment/<env>/` beside `local`, for whatever
target comes next.

**Why:** The task layout assumes more than one environment (every
environment task takes `[environment]`, and KUBECONFIG and state are
per environment), but only `local` has exercised it. A second
environment proves that adding one needs no new tasks.

**Context:** Each environment directory must provide what the shared
tasks rely on:
- a `state_directory` variable, which `.mise/lib.sh` sets through
  `TF_VAR_state_directory`;
- a `kubeconfig_path` output, read by the `verify`, `apply` and
  `conformance` tasks;
- a local backend configured by `init_environment`;
- an `environment/<env>/mise.toml` that sets `KUBECONFIG`, trusted by
  `mise run repo:setup`;
- `tests/integration.bats` for `env:test`.

The `orb:*` tasks and `ubuntu:verify` target modules by address
(`module.vm_orb`, `module.os_ubuntu`), so they only work in environments
that use those modules. Decide whether component tasks should detect
that and fail with a clear message. A stub environment could prove the
contract before a real target exists. The target and its providers are
still undecided.

**Effort:** M
**Priority:** P4
**Depends on:** A chosen target.

## Completed

### Extract multi-line mise task shell into scripts

Done on the `refactor/mise-file-tasks` branch:
- The shell moved into mise file tasks (`.mise/tasks/<noun>/<verb>.sh`)
  that share `.mise/lib.sh`.
- `FIRMAMENT_STATE_HOME` is defined once, and each environment directory
  sets its own `KUBECONFIG`.
- After apply, the tasks wait for k0s to reconcile every Helm chart. Instead
  of comparing `.status.revision` before and after, they compare
  `.status.valuesHash` with the current spec, the same test k0s itself uses.

### Move OrbStack variables out of the shared task library

Done on the `refactor/mise-file-tasks` branch. `environment/local` now
defaults `orbstack_ssh_key_path` to `~/.orbstack/ssh/id_ed25519` itself
(`pathexpand` in `main.tf`), and `.mise/lib.sh` passes only the state
directory. `TF_VAR_orbstack_ssh_key_path` replaces the
`FIRMAMENT_ORBSTACK_SSH_KEY` override.
