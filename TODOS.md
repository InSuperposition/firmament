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

### Shorten the single-pass e2e lane

**What:** Plan how to cut `env:e2e` below its current ~17 minutes,
starting from where the time goes.

**Why:** A shorter lane gets run more often, and fewer fresh image
pulls make it less exposed to network outages. The first live attempt
failed because an internet drop made pulls from quay.io time out on DNS.

**Context:** Approximate times for one pass, from the 2026-09-23 run
(two passes, 33 minutes):

| Step | Time |
| --- | --- |
| `env:destroy` (init, plan, k0s reset 29s to 1m) | ~45s to 1m15s |
| `env:apply`: VM create | ~15s |
| `env:apply`: k0s install through k0sctl | 2m11s |
| Post-apply wait: `cilium status`, charts, node | ~2 min |
| `verify` (Cilium, chainsaw, node, Ubuntu probe) | ~20s |
| `cilium:conformance` + cleanup (79 of 137 tests, serial) | ~9 to 11 min |

Every rebuild starts from a fresh VM, so k0s and every image (Cilium,
Envoy, Hubble, CoreDNS) are downloaded again. Ideas to evaluate:
- a pull-through registry cache on the host for quay.io and docker.io,
  which would also let the lane survive internet drops;
- a k0s airgap image bundle that k0sctl uploads, kept in step with the
  pinned Cilium version;
- a conformance subset (`--test`) or `--test-concurrency`, weighed
  against what each skipped test covers;
- keeping the VM between the two destroys and resetting only k0s,
  weighed against no longer testing a fresh machine.

Also check why conformance reports "Unable to contact Hubble Relay,
disabling Hubble telescope and flow validation": the suite runs from
the host, which cannot reach the Relay without a port-forward, so flow
validation is skipped on every run.

**Effort:** M
**Priority:** P3
**Depends on:** None

### Test a chart value rollout on a live cluster

**What:** Add an `env:e2e` pass that changes one Helm chart value,
applies it, and asserts that only the affected pods roll, with no k0sctl
cluster reset.

**Why:** k0s upgrades charts in place (`forceUpgrade: false`), and
Cilium rolls pods on configuration changes. That path is untested live.

**Context:** `environment/local` has no input that changes a chart
value (`operator_replicas = 1` is fixed in `main.tf`). Adding a variable
only for a test was rejected. Do this item when an environment gains a
real chart-value input.

**Effort:** S
**Priority:** P4
**Depends on:** A real chart-value input.

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
The uninstall path (removing Cilium from `helm_charts` makes k0s
uninstall it) has no live test yet. Add one as an `env:e2e` pass with a
chainsaw `error` assertion on the Cilium DaemonSet, as part of this
work.

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
- `tests/integration.bats` for `env:test`;
- `tests/cluster/chainsaw-test.yaml` for `env:verify`.

Each environment writing its own cluster suite is a stopgap. Before
adding the second environment, plan a shared suite that every
environment runs with its own values (for example, a chainsaw suite
parameterized by `--values` from environment outputs), so the suites
are not copied from environment to environment.

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

### Add a live end-to-end test lane for an environment

Done on the `test/env-e2e` branch. `env:e2e [environment]` destroys the
cluster, rebuilds it, runs `verify` and `cilium:conformance`, then
destroys it again (about 17 minutes). The lane stops at the first
failure and leaves the cluster up. `cilium:conformance` now removes its
test workloads after a passing run.

The first version rebuilt the cluster twice, once per kube-proxy mode.
It passed its first live run on 2026-09-23 in 33 minutes, with
conformance at 79/79 in both modes. No environment runs kube-proxy, so
`environment/local` now fixes `kube_proxy_replacement = true`, and the
lane runs one pass. Both modules keep the input and its offline tests.

An earlier attempt stopped at the first `env:apply`, because an internet
outage made image pulls from quay.io time out on DNS. The lane left the
cluster up with the cause visible in the pod events, as designed.

Layers, from deterministic to destructive:
- `tofu test` owns HCL logic.
- bats owns shell, process and CLI behavior.
- chainsaw owns read-only Kubernetes resource state.
- The `cilium` CLI owns Cilium health and its connectivity suite.
- `env:e2e` only composes these.

### Adopt chainsaw for read-only cluster assertions

Done on the `test/chainsaw-env-verify` branch:
- chainsaw 0.2.15 is pinned through mise.
- `environment/local/tests/cluster/chainsaw-test.yaml` asserts that the
  nodes are Ready, that kube-proxy does not run, and that Cilium replaces
  it on the netkit datapath. `env:verify [environment]` runs it, and it
  joins `verify`.
- `chainsaw:lint` checks the schema and a read-only allowlist: the suite
  must use kube-system (chainsaw otherwise creates a namespace per
  test), `try` may only assert or expect errors, and `catch`/`finally`
  may only collect diagnostics. hk runs it when a suite changes.
- The chart-reconcile wait stays in `.mise/lib.sh`, because chainsaw's
  JMESPath has no `sha256`. `k0s:verify` and `cilium:verify` are
  unchanged.

### Move plan-level module suites to `tofu test`

Done on the `test/tofu-test-module-suites` branch:
- `tofu:test` runs every `tests/*.tftest.hcl` offline and joins `test`.
- cni-cilium (`unit.tftest.hcl`) and orch-k0s (`unit.tftest.hcl`, plus
  `creation.tftest.hcl` for the creation-time kube-proxy guard) moved
  off bats. A mutation check failed the same tests in both suites before
  the bats files were deleted.
- Three tests that assert OpenTofu's own errors stay on bats in
  `tests/inputs.bats`, because `expect_failures` only matches custom
  conditions.
- os-ubuntu, vm-orb and `environment/local/tests/integration.bats` stay
  on bats. The environment suite would need a plan-known rendered-config
  output from orch-k0s, since a root-level `tofu test` cannot address
  resources inside nested modules. Add that output only when a real
  consumer needs it.

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
