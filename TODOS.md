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

### Add Flux Operator and hand Cilium and Flux to Flux

**What:** Build new clusters in which Flux owns Cilium and Flux itself from
creation. An OpenTofu bootstrap Job installs Cilium, Flux Operator and a
`FluxInstance`. From then on, Flux reconciles both components from Git.
k0s installs no Helm charts.

**Scope:** This work adds only two components: `cni-cilium` and
`gitops-flux`. Kyverno, Crossplane, Timoni, a registry and additional
environments are separate work (see "Later: platform planning").

**Why:** Cilium upgrades should flow through Git instead of k0s cluster
configuration changes, and Flux must be able to upgrade itself.

**Context:** Engineering review and two Codex reviews on 2026-09-24.
Declarative, deterministic and reproducible are the priorities.

Ownership:
- L1, the substrate (`vm-orb`, `os-ubuntu`, `orch-k0s`), always stays on
  OpenTofu.
- L2, the bootstrap, is the upstream `flux-operator-bootstrap` module. It
  installs Cilium, Flux Operator and the `FluxInstance` once. It also
  keeps its transport objects and the `flux-runtime-info` ConfigMap,
  which it re-applies on every run. Flux must not manage that ConfigMap.
- L3, the in-cluster add-ons, belongs to Flux from Git. OpenTofu never
  creates L3 resources, so orch-k0s loses its `helm_charts` input.

Why rebuild instead of migrating: k0s turns each chart into a `Chart`
named `k0s-addon-chart-<name>` with finalizer
`helm.k0sproject.io/uninstall-helm-release`, and deleting it uninstalls
the release. A live handoff would race that finalizer. `env:e2e`
rebuilds `local` in about 17 minutes, so new clusters start with Flux as
the owner. The k0s-to-Flux transition is tested only through a rebuild.

Files:

```text
components/                          # Flux-owned packages (plain Kustomize, not kind: Component)
├── cni-cilium/
│   ├── kustomization.yaml           # configMapGenerator: cilium-values, no name suffix
│   ├── ocirepository.yaml           # chart URL + digest
│   ├── helmrelease.yaml             # identity, remediation, valuesFrom cilium-values
│   ├── values.yaml                  # shared by the bootstrap and Flux
│   └── tests/values.bats            # every former cni-cilium assertion
└── gitops-flux/
    ├── kustomization.yaml
    ├── ocirepository.yaml           # Flux Operator chart URL + digest
    ├── helmrelease.yaml             # Flux Operator, values inline
    └── fluxinstance.yaml            # distribution, sync, root customization
environment/local/
├── main.tf                          # substrate composition (existing)
├── providers.tf                     # decodes the kubeconfig; helm + kubernetes providers
├── bootstrap.tf                     # module "bootstrap_flux" + runtime values
├── variables.tf                     # adds git_branch
├── flux/kustomization.yaml          # selects cni-cilium and gitops-flux
└── tests/                           # integration.bats, cluster/chainsaw-test.yaml (extended)
modules/orch-k0s/                    # Helm extension removed; drain_before_upgrade added
.mise/lib.sh                         # rendering, ref validation, Flux readiness wait
.mise/tasks/flux/lint.sh             # new task: flux:lint
.mise/tasks/cilium/test.sh           # cilium:test moves out of mise.toml
.mise/tasks/env/{apply,destroy,e2e,verify}.sh   # extended
.fluxschema.yml                      # flux-schema settings only
```

`modules/cni-cilium` is deleted. `components/` holds only Flux-owned
packages, and `modules/` holds only OpenTofu. README defines both words
and the ownership layers.

Plan:
1. Spike on a fresh local cluster. `providers.tf` decodes
   `module.orch_k0s.kube_yaml` and passes its server, CA and client
   credentials to the hashicorp/helm and hashicorp/kubernetes providers
   (>= 3), whose locks are committed. Prove that one `env:apply` works
   while the cluster is unknown at plan time. Only if it fails,
   `env:apply` first targets `module.orch_k0s` and
   `local_sensitive_file.kubeconfig`, then applies everything. Keep one
   state.
2. `bootstrap.tf` calls upstream directly as `module "bootstrap_flux"`,
   with no local wrapper module. The source is pinned to a full commit
   SHA (`?ref=<sha>`), and a comment records the tag (`v0.8.0`). Before
   Cilium exists, kube-proxy is off and the node is NotReady, so the Job
   needs:
   - `job.host_network`;
   - `job.env` setting `KUBERNETES_SERVICE_HOST` and
     `KUBERNETES_SERVICE_PORT` to the API address;
   - tolerations for `node.kubernetes.io/not-ready` and
     `node.cilium.io/agent-not-ready`.

   Cilium is a prerequisite chart with `flux_adoption_check` on the
   Cilium DaemonSet. The bootstrap reads each chart's repository and
   digest from the component's `ocirepository.yaml` and installs
   `<repository>@sha256:<digest>`. It reads Cilium values from
   `components/cni-cilium/values.yaml`, and Flux Operator values from
   `spec.values` in its HelmRelease, through
   `yamldecode()`/`yamlencode()`. Every pin is declared once, in the
   component.

   The bootstrap `revision` comes from a local `bootstrap_revision = 1`.
   Increment it only to rerun the bootstrap on purpose, for example to
   retry a failed bootstrap without destroying the VM. An unchanged
   second apply must not rerun it.
3. Runtime values. `runtime_info` carries six keys from one OpenTofu
   local:
   - `api_address` and `api_port`, from the substrate outputs;
   - `kube_proxy_replacement`;
   - `cilium_datapath_mode` (`netkit` or `veth`), derived in OpenTofu from
     `kube_proxy_replacement`;
   - `cilium_operator_replicas` (1 for local);
   - `git_branch`, the only new root input.

   Flux substitution is plain text replacement: it cannot evaluate the
   old template's HCL conditional or `jsonencode()`. OpenTofu therefore
   computes every derived value, `api_address` is quoted, and booleans
   and integers keep their types.
4. `components/cni-cilium/kustomization.yaml` generates the ConfigMap
   `cilium-values` from `values.yaml`, with `disableNameSuffixHash: true`
   and the label `reconcile.fluxcd.io/watch: Enabled`. The HelmRelease
   reads it through `valuesFrom`, so a values change triggers an upgrade.
5. `components/gitops-flux/` holds the Flux Operator HelmRelease and the
   `FluxInstance`. The bootstrap only upgrades these until Flux adopts
   them, so without this component the operator is never upgraded again.
6. Release identity, so that Flux adopts the bootstrap releases instead
   of installing second copies. Every source, Kustomization and
   HelmRelease lives in `flux-system`.
   - Cilium: `releaseName: cilium`, `targetNamespace: kube-system`,
     `storageNamespace: kube-system`.
   - Flux Operator: `releaseName: flux-operator`, target and storage
     namespace `flux-system`.
7. Source and reconciliation:
   - The `FluxInstance` `flux-system/flux` syncs a `GitRepository` on
     <https://github.com/InSuperposition/firmament.git> at
     `refs/heads/${git_branch}`, path `environment/<env>/flux`.
   - The generated source and root Kustomization are both named
     `flux-system`. Root substitution from `flux-runtime-info` is
     configured through `FluxInstance` patches.
   - The root Kustomization applies both components directly and
     health-checks both HelmReleases. The bootstrap installs both charts
     and their CRDs before Flux reads Git, so no child Kustomizations or
     `dependsOn` are needed yet. Add them when a component brings CRDs
     of its own.
   - The guarantee is "verified revision under a stable branch".
     Following a branch is intentional, so Flux applies new commits by
     itself. `env:e2e` verifies the exact SHA it tested.
8. Pins. The same commit must install the same bytes:
   - bootstrap module: full commit SHA;
   - Cilium and Flux Operator charts: `OCIRepository.spec.ref.digest`,
     which the bootstrap reads as well;
   - workload images: digests for every enabled image (for Cilium, the
     chart's `useDigest` settings), and tests fail on any rendered image
     without `@sha256:`;
   - Flux: an exact `FluxInstance.distribution.version`, the Flux
     Operator image by digest, and the manifests embedded in that image
     (no external `distribution.artifact`);
   - providers: committed `.terraform.lock.hcl`, and `init_environment`
     and `init_offline` run `tofu init -lockfile=readonly`;
   - tools: exact versions in `mise.toml`, with checksums in `mise.lock`
     for every platform entry, including bats (missing today). The Flux
     CLI is pinned for `flux envsubst`.

   Known exception: the upstream v0.8.0 Job image is selected by
   chart-version tag and cannot be pinned by digest without an upstream
   change. Do not fork for it.
9. Reproducibility boundary. Outside what this repository pins: the
   `ubuntu:resolute` image, OrbStack's app and kernel, host resources,
   SSH keys, the network, and generated certificates. Live tests record
   the OrbStack and kernel versions. They never compare certificates,
   UIDs or timestamps across rebuilds.
10. Pruning: the Cilium HelmRelease, the Flux Operator HelmRelease and the
    `FluxInstance` carry `kustomize.toolkit.fluxcd.io/prune: disabled`.
    Removing them requires an explicit teardown, never an accidental Git
    deletion.
11. Upgrade settings on every HelmRelease:
    - `upgrade.strategy.name: RemediateOnFailure`;
    - `upgrade.remediation.retries: 3`, `strategy: rollback`,
      `remediateLastFailure: true`;
    - `upgrade.force: false` and `rollback.force: false`.

    A rollback does not count as delivering the requested version.
    Cilium values pin `envoy.enabled: true`, so L7 traffic survives
    agent-only restarts. This does not protect traffic when Envoy itself
    rolls.

    Cilium minor bumps: first upgrade to the latest patch of the current
    minor, then move one minor at a time. Keep `upgradeCompatibility` at
    the initially installed version until an explicitly tested migration
    changes it.
12. orch-k0s: remove the `helm_charts` input, its Helm extension rendering
    and its 8 tests, and add one `tofu test` run asserting that the
    rendered ClusterConfig has no `extensions`. Add
    `drain_before_upgrade` (default `true`), which maps once to the
    provider's `no_drain = !var.drain_before_upgrade`.
    `environment/local` sets it `false`, because on one node a drain
    evicts every pod with nowhere to go.
13. Tasks:
    - Readiness: delete `wait_for_charts` and `chart_states` from
      `.mise/lib.sh`. `wait_for_cluster` waits for FluxInstance Ready and
      HelmRelease cilium Ready, then `cilium status`. `k0s:apply` becomes
      L1-only and waits for the node to register. Update the task
      descriptions to match.
    - `env:destroy` runs `tofu state rm module.bootstrap_flux`, then a
      full destroy, so destroy works with a dead API. A missing VM is a
      separate case: k0sctl still resets on destroy. Claim that case only
      after a live test proves the pinned provider (0.0.3) tolerates an
      unreachable host.
    - Branch input: tasks take an explicit branch variable, and detached
      worktrees never infer one. Validate the branch with
      `git check-ref-format` and the allowlist `[A-Za-z0-9._/-]`, because
      upstream v0.8.0 interpolates runtime values into a shell command.
    - `env:e2e [environment]` fetches, then refuses to start unless the
      working tree is clean (untracked files included), the remote branch
      exists and HEAD equals `origin/<branch>`. It records the expected
      SHA once and fails if the remote tip moves during the run.
    - `env:e2e [environment] --from-ref <ref>` also tests an upgrade.
      This replaces a separate `env:upgrade` task:
      - it resolves `<ref>` to a SHA once and checks it out with
        `git worktree add --detach`;
      - it requires an empty environment, and refuses while that
        baseline still installs Cilium through k0s;
      - it applies the baseline from the worktree and the branch from the
        checkout, against the same explicit state home;
      - it verifies the baseline SHA, switches `git_branch`, and verifies
        the branch SHA;
      - it leaves the cluster up on failure.

      Run it before merging any version bump: k0s, Cilium, Flux, Flux
      Operator or the k0sctl provider.
    - `flux:lint`: render `environment/<env>/flux` with `kubectl
      kustomize`, substitute test values with the pinned
      `flux envsubst --strict`, and validate with `flux-schema validate`
      (v0.13.0, built-in catalog, offline). It validates the environment
      build once; components are not validated separately. The shared
      rendering lives in `.mise/lib.sh`. `lint` runs it, and hk runs it
      when `components/**` or `environment/*/flux/**` change.
14. Wiring: `cilium:test` moves to `.mise/tasks/cilium/test.sh` and runs
    `components/cni-cilium/tests/values.bats`.
    `environment/local/tests/integration.bats` stops asserting the k0s
    Helm extension and asserts the bootstrap wiring instead. The hk
    pre-push `test` glob adds `components/**`.

Guarantees this plan tests (and nothing broader):
- A fresh `env:apply` builds the cluster, and Flux adopts both
  bootstrap releases without a second install.
- A second `env:apply` plans zero changes
  (`tofu plan -detailed-exitcode` returns 0).
- The same commit renders the same manifests, with every image pinned by
  digest.
- `env:e2e --from-ref` keeps the listed unaffected workloads on the same
  pods: pod UIDs, container IDs and restart counts are unchanged. Health
  is reported separately from traffic continuity. Continuity is claimed
  only if a continuous traffic probe shows no gap.

Tests:
- `components/cni-cilium/tests/values.bats` (bats + yq) keeps every
  behavior the old `cni-cilium` suites asserted:
  - chart 1.20.2 in kube-system, upgrades patched and never forced;
  - netkit with BPF masquerading, and veth when kube-proxy runs (both
    modes);
  - `ipam.mode: kubernetes`;
  - Hubble Relay and UI, with certificates renewed by a CronJob;
  - pods roll on configuration changes;
  - `socketLB.hostNamespaceOnly`;
  - Cilium operator replicas of 1 and 2;
  - API address, port and kube-proxy mode taken from runtime variables.

  It also asserts the remediation settings, `envoy.enabled: true`, the
  release identities, the prune annotations, image digests and the
  `cilium-values` wiring. It checks that the values the bootstrap
  installs equal the values Flux renders.
- `flux:lint` validates the rendered environment build in `mise run
  check`.
- chainsaw adds, with the Flux assertions pointed explicitly at
  `flux-system`:
  - FluxInstance Ready;
  - the Cilium and Flux Operator HelmReleases Ready and labeled
    `helm.toolkit.fluxcd.io/name`;
  - no k0s `Chart` objects;
  - the root Kustomization `lastAppliedRevision` equal to
    `<branch>@sha1:<HEAD>`, with the branch and SHA passed in through
    `--values`.
- bats covers:
  - the `env:destroy` order and destroy with a dead API;
  - the `env:e2e` preconditions: dirty tree, missing remote branch,
    remote tip moved, invalid branch name;
  - the `--from-ref` refusal on a k0s-owned baseline.
- A `tofu test` run asserts that `drain_before_upgrade = false` reaches
  `k0sctl_config` as `no_drain = true`.

**Effort:** L
**Priority:** P3
**Depends on:** None

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
