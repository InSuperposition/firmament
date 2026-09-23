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

The next item finishes a three-phase plan, ordered from deterministic
to destructive:
1. `tofu test`: offline and deterministic (done; see Completed).
2. chainsaw: live, read-only (done; see Completed).
3. `env:e2e`: live, destructive.

Each phase depends on the one before it. Each layer owns one concern:
- `tofu test` owns HCL logic.
- bats owns shell, process and CLI behavior.
- chainsaw owns read-only Kubernetes resource state.
- The `cilium` CLI owns Cilium health and its connectivity suite.
- `env:e2e` only composes existing tasks.

### Add a live end-to-end test lane for an environment

**What:** Add an `env:e2e [environment]` file task
(`.mise/tasks/env/e2e.sh`, with `#MISE confirm`) that rebuilds the
cluster twice and composes existing tasks only:

```text
pass 1  TF_VAR_kube_proxy_replacement=true
  env:destroy -y, env:apply, check output, verify, cilium:conformance,
  flip guard (env:plan with the mode false must fail with
  "fixed at cluster creation"), env:destroy -y
pass 2  TF_VAR_kube_proxy_replacement=false
  env:apply, check output, verify, cilium:conformance, env:destroy -y
```

**Why:** The offline suites cannot catch regressions that only appear on
a live cluster, and those paths are currently checked by hand.

**Context:**
- **Paths it covers:**
  - the post-apply chart wait;
  - every `*:verify` task and `cilium:conformance`;
  - the kube-proxy-off bootstrap and its veth datapath;
  - the creation-time guard on a live cluster.
- **Mode per pass.** Set `TF_VAR_kube_proxy_replacement` explicitly in
  each pass, and check the `kube_proxy_replacement` output after each
  apply, so an inherited value cannot make both passes test the same
  mode.
- **Failure handling.** On failure, stop, print the failed step and
  `mise run env:destroy -y <env>`, and leave the cluster up for
  debugging. There is no trap; the next run starts with a destroy.
  `cilium:conformance` runs `cilium connectivity test --cleanup` only
  after a passing suite.
- **Duration.** A run takes about 30 to 40 minutes, so keep it out of
  `check`, `test` and the Git hooks. `env:e2e local` destroys the only
  local cluster; the confirm text says so.
- **Tests.**
  - The "read-only tasks never apply or destroy" test in
    `.mise/tests/tasks.bats` only greps tofu calls. Skip `e2e.sh` there
    by name, and add a stubbed sequence test for it.
  - Test the kube-proxy mode with an opposing inherited value.

**Effort:** M
**Priority:** P2
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
**Depends on:** The e2e lane, and a real chart-value input.

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
- a `kube_proxy_replacement` output, read by `env:verify`;
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

### Adopt chainsaw for read-only cluster assertions

Done on the `test/chainsaw-env-verify` branch:
- chainsaw 0.2.15 is pinned through mise.
- `environment/local/tests/cluster/chainsaw-test.yaml` asserts that the
  nodes are Ready, and that kube-proxy and the Cilium datapath match the
  new `kube_proxy_replacement` output. `env:verify [environment]` runs
  it, and it joins `verify`.
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
