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

**What:** Add an `env:e2e` pass that changes one Helm chart value
through Git, lets Flux apply it, and asserts that only the affected pods
roll, with no cluster reset.

**Why:** Once Flux owns Cilium, chart values change through a Git
commit and a HelmRelease upgrade, which must patch and never force
(the hubble-generate-certs Job cannot be recreated in place). Cilium
rolls pods on configuration changes. That path is untested live.

**Context:** No environment has a real chart-value input yet. Adding a
value only for a test was rejected. Do this item when an environment
gains a real chart-value input.

**Effort:** S
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux; a
real chart-value input.

### Prove Flux-owned upgrades with `env:e2e --from-branch`

**What:** Run the first live upgrade test once a baseline where Flux owns
Cilium is on main, and add a traffic probe.

**Why:** `env:e2e --from-branch <branch>` exists and is tested offline,
but it has never run live: every baseline before the Flux handoff
installs Cilium through k0s, and the task refuses those.

**Context:**
- Once the Flux handoff is merged, run `mise run env:e2e --from-branch
  main` from a branch that bumps something (for example the next Cilium
  patch).
- The upgrade lane already checks that the workloads in
  `environment/local/tests/upgrade-unaffected` (CoreDNS, metrics-server)
  keep their pod UIDs, container IDs and restart counts across the
  switch, and `verify` reports health. It does not measure traffic, so it
  claims no traffic continuity. Add a probe that runs through the whole
  upgrade and shows no gap before claiming it; it needs a test workload,
  which the read-only chainsaw suite cannot deploy.
- Accepted risks for the local cluster, to revisit before any non-local
  environment:
  - Flux follows the branch tip, not the commit `env:e2e` tested, so
    anyone who can push to the branch gets cluster-admin through Flux;
    branch protection is the guard.
  - The upstream bootstrap Job runs with host networking and
    cluster-admin, and its image is selected by tag (v0.8.0); upstream
    offers no digest option, and mirroring it needs the registry deferred
    in "Run an OCI registry on the host".
- Known pinning exceptions, to revisit rather than fix blindly:
  - the upstream bootstrap Job image is selected by tag (v0.8.0);
  - k0s's own konnectivity, CoreDNS and metrics-server images run by tag;
  - bats installs from a GitHub source archive, which has no published
    checksum, so `mise.lock` records none for it;
  - the OrbStack provider only exists for macOS, so `environment/local`
    and `modules/vm-orb` lock darwin platforms only.
- k0sctl reset over OrbStack's SSH (127.0.0.1:32222) sometimes hangs after
  the reset finishes: the last remote command stays `<defunct>` under
  `orbstack-agent`, so the channel never closes (25 minutes in the
  2026-09-24 e2e run; other destroys took about 40 seconds). With
  `/var/lib/k0s` gone and `k0scontroller` inactive, `orb restart
  <machine>` drops the session and the destroy completes. Never
  interrupt tofu twice: a forced exit wiped the state file once. Decide
  whether `env:destroy` should detect this, or whether a newer k0sctl
  provider fixes it.
- `firmament.orb.local` resolves on the host to an OrbStack proxy address
  (192.168.138.x), not the VM IP. Once, right after k0s came up, that
  address timed out while the VM IP answered, and a rerun passed. If it
  recurs, point the Helm and Kubernetes providers at the VM IP.

**Effort:** M
**Priority:** P3
**Depends on:** The Flux handoff merged to main.

### Make destroy and apply deterministic by holding less state

**What:** Decide how `env:destroy` and `env:apply` stay correct when a
step fails partway, preferably by removing in-cluster objects from
OpenTofu state instead of adding recovery code.

**Why:** `env:destroy` removes `module.bootstrap_flux` from state before
it destroys the rest, so it works when the API server is already gone.
If the destroy then fails partway (the k0sctl reset hang over OrbStack's
SSH, an unreachable host), the VM and the bootstrap objects still exist
but state no longer tracks the bootstrap, and the next `env:apply` fails
on a name already in use. Recovery today is manual: restore from
`terraform.tfstate.bootstrap.backup` in the state directory. Separately,
`env:apply` reports success once the FluxInstance and the Cilium
HelmRelease are Ready, which on an existing cluster can happen before
Flux has applied the pushed commit; `env:verify` and `env:e2e` wait for
the exact revision, `env:apply` alone does not.

**Context:** Prefer designs that leave nothing to recover:
- Keep the bootstrap out of OpenTofu state. k0s applies manifests placed
  in `/var/lib/k0s/manifests/<stack>` and prunes a stack when its files
  go away; k0sctl can upload them. OpenTofu would then hold no
  in-cluster object, so destroy never needs the API server. Check that
  it still covers the pre-CNI Job settings and the runtime ConfigMap.
- Treat the machine as the unit of destroy: deleting the VM removes
  everything inside it, so the state of in-cluster objects can be
  dropped with it rather than destroyed one by one.
- OpenTofu features not used yet: `removed` blocks with
  `lifecycle { destroy = false }`, and `destroy -exclude`, which keep
  state consistent at every step. Prove any of them on a live destroy
  with the API server gone.
- One definition of done for apply, verify and e2e: Flux has applied the
  intended revision and it is healthy. Flux Operator's CLI
  (`flux-operator wait`), FluxInstance status, or an OCI artifact pinned
  by digest (see "Run an OCI registry on the host") could give
  `env:apply` an exact target without requiring a pushed branch, which
  would hurt local iteration.

**Effort:** M
**Priority:** P3
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Give each worktree its own live environment

**What:** Derive the OrbStack machine name, the state directory and the
kubeconfig path from the worktree, so several worktrees can each run a
live cluster at once.

**Why:** Every worktree shares one state directory and one machine per
environment. The ownership guard (`claim_environment` in `.mise/lib.sh`)
stops one worktree from rebuilding or destroying another's cluster, but
live testing stays serial: one cluster, one `env:e2e`, at a time.

**Context:** The name would need to reach `vm_orb` (machine name),
`orch_k0s` (host and API address), `FIRMAMENT_STATE_HOME` and the
kubeconfig paths in each `environment/<env>/mise.toml`. Each machine
uses about 1.5 GB of memory, so decide first how many can run at once on
the host. Worktrunk's `{{ branch | hash_port }}` shows one way to derive
stable per-branch values.

**Effort:** M
**Priority:** P4
**Depends on:** None.

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

If the "Plan Crossplane" item is adopted, decide whether the second
environment is an `environment/<env>/` OpenTofu root or a Crossplane XR.

If the second environment has several nodes, plan rolling upgrades:
keep k0sctl draining (`drain_before_upgrade` true), or adopt k0s
autopilot `Plan`s. Autopilot would move k0s version ownership from
OpenTofu into Git, so decide that against the ownership rules first.

**Effort:** M
**Priority:** P4
**Depends on:** A chosen target.

## Later: platform planning

Abstract: Candidate work to reevaluate once Flux owns Cilium and Flux
itself. These items promise no order and no commitment. Version facts
were checked on 2026-09-24; re-check them when a plan starts.

### Plan Timoni for Flux components

**What:** Decide whether to write `components/` as Timoni modules.

**Why:** Timoni gives typed, composable modules. The Flux plan starts
with plain YAML to prove Flux first.

**Context:** Timoni v0.34.0 added `timoni mod vet` (validates rendered
custom resources against CRD schemas and CEL), `timoni bundle update` and
drift exit codes for `apply --diff`. Flux cannot evaluate CUE, so Timoni
must render YAML before Flux sees it: committed to Git (with an hk check
that the output is fresh) or pushed as an OCI artifact. Compare it with
flux-schema validation and with Flux Operator `ResourceSet` templating.
mise can pin it as `aqua:stefanprodan/timoni`. Guide:
<https://timoni.sh/gitops-flux/>.

**Effort:** S
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Plan Kyverno

**What:** Decide whether admission policy is needed, and with which
engine.

**Why:** Admission policy can enforce preconditions for safe rollouts
(a PodDisruptionBudget, at least 2 replicas, readiness probes).

**Context:** First decide whether Kubernetes native
ValidatingAdmissionPolicy and MutatingAdmissionPolicy are enough. If
Kyverno is needed, write policies only in the CEL types
(`policies.kyverno.io/v1`), because ClusterPolicy and Policy are
deprecated and scheduled for removal in 1.20. A Kyverno outage must not
block the components that repair the cluster. Policy exclusions alone do
not stop the API server from calling an unavailable webhook, so plan
exemptions on the webhook configuration itself, including cluster-scoped
resources and the bootstrap namespace. Test repairs while Kyverno is
down.

**Effort:** M
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Plan Crossplane

**What:** Decide whether Crossplane should own resources outside the
cluster, and which ones.

**Why:** The goal discussed on 2026-09-24: Crossplane, not OpenTofu,
owns external resources once a cluster exists. It needs a real consumer
and a lifecycle plan first.

**Context:** Open questions from the 2026-09-24 review:
- What does Crossplane manage first? No consumer exists yet.
- Boundary: L1 (the VM, OS and k0s node) always stays on OpenTofu.
  External resources ("L4") exclude L1.
- Lifecycle: `env:e2e` destroys this cluster, and Crossplane keeps its
  state in etcd. Plan how provider credentials survive bootstrap,
  restart, reboot and disaster, and how external resources are re-adopted
  after a rebuild (external names, `managementPolicies`,
  `deletionPolicy: Orphan`) without duplicate provisioning.
- Ordering: Crossplane cannot run before Cilium or Flux in the same
  cluster, because its pods need the CNI and its inputs arrive through
  Flux. It could provision another cluster before that cluster's own
  Cilium and Flux.
- Its Helm chart is not published as an OCI chart, so Flux would install
  it, not the bootstrap Job.

**Effort:** L
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Plan blue/green cluster upgrades

**What:** Decide whether to upgrade by replacing whole clusters.

**Why:** With one node, VM image, OS, kernel, and k0s or Cilium minor
upgrades have no spare copy to fail over to.

**Context:** Options to evaluate: Cilium ClusterMesh global services with
`service.cilium.io/affinity`, DNS or Gateway API cutover, and Flagger
canaries over Gateway API routes for apps. State the guarantees that
would be tested; avoid blanket "without user impact" claims. It needs a
host that can run two clusters and an answer for resources that must
survive a cluster being replaced.

**Effort:** L
**Priority:** P4
**Depends on:** Plan Crossplane, if Crossplane provisions the clusters.

### Run an OCI registry on the host

**What:** Run a local OCI registry next to OrbStack, as a Flux source
and as a pull-through image cache.

**Why:** Flux reads from GitHub, so every cluster change needs a push.
A local cache would also cover some of the internet drops that failed an
earlier e2e run.

**Context:** Deferred on 2026-09-24 as too much for the first Flux
plan. A registry alone does not make bootstrap offline: Git, binaries,
OpenTofu providers and any image not yet cached are still fetched. It
adds a long-lived process, so plan its lifecycle (start, restart, reboot,
disaster). Its data can be rebuilt.

**Effort:** M
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

## Completed

### Add Flux Operator and hand Cilium and Flux to Flux

Done on the `feat/flux-bootstrap-spike` branch. Every commit passes
`check`, and each change to the cluster was proven on a fresh live apply:
- The Helm and Kubernetes providers read the kubeconfig orch_k0s
  returns; one `env:apply` works while it is unknown at plan time.
- The upstream flux-operator-bootstrap module (v0.8.0, pinned by commit)
  installs Flux Operator and the `FluxInstance`, and Flux manages both
  from `components/gitops-flux`.
- Cilium moved from the k0s Helm extension to `components/cni-cilium`:
  the bootstrap installs it before any pod network exists and Flux
  adopts it. orch-k0s lost `helm_charts` and gained
  `drain_before_upgrade`.
- `env:e2e` tests exactly the pushed commit, records the OrbStack and
  kernel versions, and gained `--from-branch` with a pod continuity check;
  `flux:lint` validates each environment's rendered Flux build; the
  chainsaw suite checks Flux ownership and the applied revision; tofu
  init reads lock files read-only.

Live: Flux adopted both releases as revision 2 (no second install), the
root Kustomization applied the pushed SHA, and a second plan showed no
changes. `env:e2e` passed on 2026-09-24 at 8a498db, including the new
chainsaw checks and `cilium:conformance` (79/79).

Differences from the plan:
- Runtime info has a seventh key, `environment`, for the sync path.
- The bootstrap Job runs on the host network from the first commit, not
  only once it installs Cilium: it has one attempt and starts before
  CoreDNS answers.
- No `.fluxschema.yml`: `flux:lint` needs no settings beyond the
  defaults.
- The first live upgrade run and a traffic probe moved to "Prove
  Flux-owned upgrades with `env:e2e --from-branch`".

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
