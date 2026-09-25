# TODOS

Abstract: Deferred work for firmament, ordered by priority within each
section. Each item carries enough context to pick up cold.

## Planned stack

Abstract: The project is in alpha. This table is the one list of what
runs today and what is coming, so each item below can plan for its
neighbours instead of discovering them later. Each item's
**Integrates with** line names the parts it touches. Plan against the
latest release of each part, and re-check versions when a plan starts.
Versions were checked on 2026-09-25.

| Part | Role | Latest | Status | Item |
|---|---|---|---|---|
| OpenTofu, OrbStack, Ubuntu, k0s | VM, OS and Kubernetes node (L1) | pinned in repo | running | none |
| Cilium + Hubble | CNI, network flows, UI | 1.20.2 | running | "Test a Cilium version bump" |
| Flux + Flux Operator | GitOps, web UI | Operator v0.60.0 | running | "Add mise tasks to open the Hubble and Flux web UIs" |
| OpenTelemetry | telemetry: metrics, logs, traces | Collector v0.161.0, Operator v0.159.0 | chosen | "Plan telemetry with OpenTelemetry" |
| Metrics store + dashboards | Prometheus + Grafana or an alternative | Prometheus v3.15.0, Grafana v13.2.2 | planning | "Plan metrics and dashboards" |
| Kyverno | admission policy | v1.19.1 | coming | "Plan Kyverno" |
| Crossplane | external resources | v2.4.2 | coming | "Plan Crossplane" |
| CubeFS | distributed storage: CSI volumes, S3 | v3.6.0 | coming | "Plan CubeFS storage" |
| Tetragon | eBPF process and syscall events | v1.7.1 | research | "Research eBPF observability and runtime security" |
| KubeArmor | runtime enforcement | v1.7.5 | when an app runs | "Plan KubeArmor when it becomes relevant" |
| Chaos Mesh | fault injection | v2.8.4 | planning | "Plan fault injection with Chaos Mesh" |
| Timoni | typed component modules | v0.34.0 | planning | "Plan Timoni for Flux components" |

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

**Integrates with:** Each coming component adds its offline check to
`mise run check`: Kyverno policy tests (`kyverno test`), Crossplane
composition validation with its CLI, OpenTelemetry Collector config
validation (`otelcol validate`), and `flux:lint` for every new
component.

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

**Integrates with:** Every coming component (OpenTelemetry, the metrics
store, Kyverno, Crossplane) adds image pulls and start-up time. Budget
the lane per component, and let the "Run an OCI registry on the host"
cache cover their images.

**Effort:** M
**Priority:** P3
**Depends on:** None

### Add mise tasks to open the Hubble and Flux web UIs

**What:** Add one task per web UI that port-forwards to the local
cluster and opens the browser, plus a few read-only observability tasks
for day-to-day checks.

**Why:** Both UIs already run in every cluster, but reaching them means
remembering a namespace, a service and a port. A task name is easier to
find and to share than a `kubectl port-forward` line in someone's shell
history.

**Context:**
- Hubble UI is enabled in `components/cni-cilium/values.yaml`
  (`hubble.ui.enabled`). `cilium hubble ui` port-forwards to it on
  local port 12000 and opens the browser. `cilium-cli` 0.20.1 is pinned
  in `mise.toml`.
- Flux Operator v0.60.0 serves the Flux Web UI on port 9080:
  `kubectl -n flux-system port-forward svc/flux-operator 9080:9080`
  (<https://fluxoperator.dev/web-ui/>). It also supports Ingress and
  single sign-on; keep it on a port-forward for the local cluster.
- Candidate tasks: `cilium:ui`, `flux:ui`, and `cilium:observe` (runs
  `hubble observe` through a Relay port-forward; the `hubble` CLI 1.19.4
  is pinned). Each takes the environment like the other tasks and
  reads its kubeconfig.
- Lifecycle: a port-forward runs in the foreground and stops on Ctrl-C.
  No background process, no PID file. If a port is busy, fail with a
  clear message, or take a `--port` flag like `cilium:conformance`
  does with `--hubble-port`.
- Also worth listing: a terminal UI such as k9s pinned in `mise.toml`,
  and whether `cilium:conformance` could reuse the Relay port-forward so
  its Hubble flow validation stops being skipped (see "Shorten the
  single-pass e2e lane").

**Integrates with:** Grafana (or its alternative) from "Plan metrics and
dashboards" should get the same kind of task. Keep one shared port-
forward helper so each new UI is a one-line task.

**Effort:** S
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

**Integrates with:** Kyverno policies (PodDisruptionBudgets, replica
counts) change what a safe rollout needs. Once telemetry exists, check
the rollout in metrics, not only in pod state.

**Effort:** S
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux; a
real chart-value input.

### Test a Cilium version bump with `env:e2e --from-branch`

**What:** Run `env:e2e --from-branch main` from a branch that bumps the
Cilium chart to the next patch release after 1.20.2.

**Why:** The upgrade lane has passed live, but its change only annotated
the agent pods. A real bump also changes the images, the CRDs and the
chart templates, which is the upgrade that will happen in practice.

**Context:**
- The chart is pinned by digest in
  `components/cni-cilium/ocirepository.yaml`, and the bootstrap reads the
  same digest, so the bump is one digest and one comment.
- The upgrade lane already checks that the workloads in
  `environment/local/tests/upgrade-unaffected` (CoreDNS, metrics-server)
  keep their pod UIDs, container IDs and restart counts across the
  switch, and `verify` reports health.
- Traffic runs through the whole switch: `cilium:traffic-start` holds
  cilium-cli conn-disrupt connections open and starts fortio at 100 new
  connections a second through a ClusterIP Service, and
  `cilium:traffic-check` fails on any broken connection, failed request or
  rate under 90% of the one requested.
  Its last line, repeated in the run's final line, says whether the
  traffic crossed a Cilium agent restart. A branch that leaves Cilium
  alone passes with "continuity was not exercised", so the bump under
  test must replace the agent pods for the run to prove continuity.
- Accepted risks for the local cluster, to revisit before any non-local
  environment:
  - Flux follows the branch tip, not the commit `env:e2e` tested, so
    anyone who can push to the branch gets cluster-admin through Flux;
    branch protection is the guard.
  - The upstream bootstrap Job runs with host networking and
    cluster-admin, and its image is selected by tag (v0.8.0); upstream
    offers no digest option, and mirroring it needs the registry deferred
    in "Run an OCI registry on the host".
  - The fortio client that `cilium:traffic-start` deploys serves its REST
    API, which can send requests anywhere, on port 8080 to anything in
    the cluster that reaches the pod. It lives only between
    `cilium:traffic-start` and a passing `cilium:traffic-check`, and a
    failed check keeps it for inspection.
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

**Integrates with:** With OpenTelemetry and a metrics store in place,
record Hubble drop counts and agent restarts during the run, next to the
fortio numbers.

**Effort:** S
**Priority:** P3
**Depends on:** A Cilium patch release after 1.20.2.

### Mirror the OpenTofu providers locally

**What:** Plan an offline provider mirror, so `tofu init` needs no
network: `tofu providers mirror` fills a directory, and a CLI
configuration with a `filesystem_mirror` block in
`provider_installation` points tofu at it.

**Why:** Every environment task runs `tofu init`. On 2026-09-25 it failed
several times with `context deadline exceeded` reaching
registry.terraform.io, because DNS on the host network stalled, and one
failure stopped an `env:e2e` run in its first minute.

**Context:**
- The network investigation lives outside this repository, in
  `../tofu-registry-network-stalls.md`. The cause is DNS: some of the
  nameservers the router hands out stop answering.
- A mirror only covers `tofu init`. The same DNS stall also failed the
  k0s download inside the VM, and image pulls go to the internet too
  (see "Run an OCI registry on the host"), so fixing DNS matters more.
- The plan must answer: where the CLI configuration lives, and how
  `mise` sets `TF_CLI_CONFIG_FILE`; how the mirror stays in step with
  each `.terraform.lock.hcl` and its checksums (the lock files are read
  only during init); which platforms it holds; and how it relates to the
  shared plugin cache in `~/.cache/firmament/tofu-plugins`.

**Integrates with:** Only OpenTofu uses it. Crossplane providers are OCI
packages, so they belong to "Run an OCI registry on the host".

**Effort:** S
**Priority:** P4
**Depends on:** None

### Plan fault injection with Chaos Mesh

**What:** Hold a planning session on adding
[Chaos Mesh](https://chaos-mesh.org/) as a Flux component that injects
faults, with the upgrade traffic probes (cilium-cli conn-disrupt and
fortio) as the measurement.

**Why:** The traffic probes only run during `env:e2e --from-branch`,
which takes about 17 minutes and needs a second branch. A `PodChaos` that
kills the Cilium agent pod causes the same agent restart in seconds, so
continuity could be checked on demand. The same setup could later kill a
Flux controller mid-reconcile or delay the API server, then check that
the cluster recovers.

**Context:**
- Chaos Mesh v2.8.4 (2026-08-18), Apache-2.0, CNCF incubating. It
  installs by Helm chart, so Flux owns it, not mise.
- It injects faults but does not measure traffic. Its only built-in
  check, the Workflow `StatusCheck`, is HTTP only and runs at most once a
  second (`intervalSeconds` minimum 1), so it cannot replace the probes.
- Its `chaos-daemon` runs privileged on every node and needs k0s's
  containerd socket path (`/run/k0s/containerd.sock`), not the default.
- `NetworkChaos` shapes traffic with `tc netem` inside the pod's network
  namespace. Chaos Mesh's source never mentions netkit, which this
  cluster's Cilium datapath uses; check that it works before relying on
  it.

**Integrates with:** Telemetry from "Plan telemetry with OpenTelemetry"
gives chaos runs a measurement beyond the probes. Kyverno and KubeArmor
policies must exempt the privileged `chaos-daemon`, and chaos
experiments are a good way to test those policies.

**Effort:** M
**Priority:** P4
**Depends on:** None; the upgrade traffic probes (conn-disrupt and
fortio) are on main.

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

**Integrates with:** Crossplane keeps its state in etcd, so a rebuild
must re-adopt external resources (see "Plan Crossplane"). Kyverno
webhooks must not block the bootstrap objects during apply.

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

**Integrates with:** Each coming component adds memory per machine:
OpenTelemetry Collector, the metrics store, Kyverno, Crossplane. Re-
measure the per-machine footprint as they land.

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

**Integrates with:** Crossplane may provision it (see "Plan
Crossplane"). Kyverno policies and the OpenTelemetry pipeline should be
components every environment gets from Git, not per-environment copies.

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

**Integrates with:** Kyverno policies, Crossplane compositions and
OpenTelemetry Collector configs are the components that would gain the
most from typed modules.

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
Kyverno is needed (v1.19.1 on 2026-09-25), write policies only in the CEL types
(`policies.kyverno.io/v1`), because ClusterPolicy and Policy are
deprecated and scheduled for removal in 1.20. A Kyverno outage must not
block the components that repair the cluster. Policy exclusions alone do
not stop the API server from calling an unavailable webhook, so plan
exemptions on the webhook configuration itself, including cluster-scoped
resources and the bootstrap namespace. Test repairs while Kyverno is
down.

**Integrates with:** Exempt the platform namespaces (`flux-system`,
`kube-system`, Crossplane, OpenTelemetry) and the privileged DaemonSets
(Cilium, Tetragon, KubeArmor, `chaos-daemon`). Kyverno exports metrics
and traces, so it joins the OpenTelemetry pipeline. Policies can check
Crossplane claims before they reach a provider.

**Effort:** M
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Plan Crossplane

**What:** Decide whether Crossplane should own resources outside the
cluster, and which ones.

**Why:** The goal discussed on 2026-09-24: Crossplane, not OpenTofu,
owns external resources once a cluster exists. It needs a real consumer
and a lifecycle plan first.

**Context:** Crossplane v2.4.2 is the latest release (2026-09-22). Open
questions from the 2026-09-24 review:
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

**Integrates with:** Kyverno can validate claims and composite
resources. Provider health and reconcile errors should flow into
OpenTelemetry. Providers are OCI packages, so they can come from "Run an
OCI registry on the host".

**Effort:** L
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

### Plan metrics and dashboards (Prometheus and Grafana, or an alternative)

**What:** Choose and plan a metrics store and dashboard tool for the
cluster. Prometheus with Grafana is the default candidate, compared with
the alternatives below. The OpenTelemetry Collector is the chosen
collector (see "Plan telemetry with OpenTelemetry"), so the store only
needs to accept what the Collector sends.

**Why:** No component exposes or stores metrics today: the Cilium
values enable no Hubble or agent metrics, and Flux reports only through
its UI and events. There is no history to answer "when did this start"
or to compare an upgrade run with the one before it. The eBPF research
item also needs somewhere to send its output.

**Context:** Versions checked on 2026-09-25:
- **Prometheus and Grafana.** Prometheus v3.15.0, Grafana v13.2.2,
  Prometheus Operator v0.94.1, and the `kube-prometheus-stack` chart
  91.5.2, which bundles them with Alertmanager, node-exporter,
  kube-state-metrics and default dashboards. The most widely used
  stack; Cilium, Hubble, Flux and Flux Operator publish dashboards and
  `ServiceMonitor` support for it. Cost: the full chart is heavy for one
  VM, and Grafana has its own users and state to manage.
- **VictoriaMetrics** (v1.152.0). Speaks the Prometheus scrape and query
  formats, understands Prometheus Operator objects through its own
  operator, and uses less memory and disk. Pairs with Grafana, or with
  its own `vmui` for quick queries. VictoriaLogs (v1.52.0) covers logs
  with the same approach.
- **Perses** (v0.54.0, CNCF sandbox). Dashboards as code, stored as
  custom resources, so Flux could own them; less mature than Grafana.
- The collector is decided: the OpenTelemetry Collector (v0.161.0),
  not Grafana Alloy (v1.20.0). Alloy is Grafana's build of the same
  idea; keep it only as a fallback. Loki (v3.7.8) and VictoriaLogs are
  the log store candidates for later.
- **Coroot** (v1.26.8). An all-in-one, eBPF-based tool with its own UI
  and automatic service maps; overlaps with Hubble and the Tetragon
  research.

Questions for the plan:
- Retention and footprint on the single OrbStack VM, which has no
  per-machine CPU or memory limits (see `modules/vm-orb/machine.tf`).
- Which metrics to turn on first: Cilium agent and operator, Hubble
  flows, Flux controllers, k0s and node.
- Whether `env:e2e` should record metrics for an upgrade run, for
  example to compare fortio numbers with Hubble drop counts.
- Storage: the project is in alpha, so by default nothing persists.
  The store keeps data in memory or an `emptyDir` and loses it when the
  VM is rebuilt, which every `env:e2e` run does. Persistence is opt-in,
  for testing a new feature or comparing runs: for example a flag on the
  apply and e2e tasks that adds a volume on the host, or a snapshot
  export before `env:destroy`. Plan where opt-in data lives, and how it
  is cleaned up.
- Dashboards as code (Grafana provisioning or Perses custom resources)
  so Flux owns them, and how to open the UI (a mise task like the Hubble
  and Flux UI tasks).

**Effort:** M
**Priority:** P3
**Depends on:** None

### Plan telemetry with OpenTelemetry

**What:** Plan OpenTelemetry as the one telemetry path for the platform
and for apps: metrics, logs and traces go through the OpenTelemetry
Collector to whichever stores "Plan metrics and dashboards" picks.

**Why:** Telemetry is how a new feature is tested and how a bug or a
misconfiguration is found, across the stack: Cilium, Flux, and the
coming Kyverno, Crossplane, Tetragon and KubeArmor. One standard
collector means each new component plugs into the same pipeline instead
of bringing its own agent.

**Context:**
- Versions on 2026-09-25: OpenTelemetry Collector v0.161.0 (the
  `opentelemetry-collector-releases` builds), OpenTelemetry Operator
  v0.159.0. The Operator manages Collectors as custom resources and can
  inject auto-instrumentation into app pods, so Flux owns both.
- Two phases:
  - Platform: the Collector scrapes the Prometheus endpoints the stack
    already has or can turn on (Cilium, Hubble, Flux, Kyverno,
    Crossplane) and collects pod logs. This helps debug the platform
    itself and can start once a store is picked.
  - Apps: traces and SDK or auto-instrumentation, once a real app runs.
    That is the trigger for this item's priority, as for KubeArmor.
- Alpha defaults: nothing persists unless a run opts in (see "Plan
  metrics and dashboards").
- Validate Collector configs offline in `mise run check`
  (`otelcol validate`), like the other components.
- Check which components can export OTLP directly and which need a
  Prometheus scrape or a log file receiver.

**Integrates with:** every item in "Planned stack". The metrics store,
the UI tasks, the Cilium bump run, Chaos Mesh, Tetragon and KubeArmor
all send or read through this pipeline. Kyverno must exempt its
namespace, and its images belong in the OCI registry cache.

**Effort:** M
**Priority:** P4
**Depends on:** A real app running on the cluster, for the app phase.
The platform phase needs only "Plan metrics and dashboards".

### Plan CubeFS storage

**What:** Plan CubeFS as the cluster's storage: persistent volumes
through its CSI driver, and possibly S3-compatible object storage
through its ObjectNode.

**Why:** Nothing in the cluster has storage beyond the node's local
disk. The opt-in persistence in "Plan metrics and dashboards", and any
real app, will need volumes that outlive a pod and can later survive a
node.

**Context:**
- CubeFS v3.6.0 (2026-08-12), Apache-2.0, a CNCF project. Its parts:
  master (cluster metadata, Raft), MetaNode, DataNode, the optional
  BlobStore (erasure coding), ObjectNode (S3 API) and a FUSE client.
  Pods mount volumes through the CSI driver (`cubefs/cubefs-csi`).
- Packaging risk: the official chart (`cubefs/cubefs-helm`) is at
  version 3.2.0 (app 3.2.0.110.0), last changed 2025-03-31, far behind
  v3.6.0. Check whether a maintained chart or operator exists. If not,
  decide between vendoring and updating the chart, or writing the
  manifests as a component. Flux owns it either way.
- Single-node fit: the master and the replicas expect several nodes.
  Check what a one-node alpha setup needs (replica count 1, directories
  instead of raw disks, memory), and whether the OrbStack VM exposes
  `/dev/fuse` for the client.
- Alpha defaults: data lives inside the VM and is lost on rebuild. Only
  an opt-in run keeps it, the same rule as the metrics store.
- Plan the lifecycle (bootstrap, restart, VM rebuild, disaster), and
  what happens to volumes when `env:e2e` destroys the cluster.

**Integrates with:**
- "Plan metrics and dashboards" and "Plan telemetry with OpenTelemetry":
  opt-in persistence can use a CubeFS volume, and CubeFS exposes
  Prometheus metrics for the Collector to scrape.
- "Plan Kyverno": its CSI node plugin and client run privileged, so they
  need exemptions.
- "Plan Crossplane": decide whether Crossplane ever provisions CubeFS
  volumes or buckets, or leaves that to the CSI driver.
- "Add a second environment": real replication needs several nodes, so
  a multi-node environment is where CubeFS is tested properly.
- "Give each worktree its own live environment" and "Shorten the
  single-pass e2e lane": several storage services add memory, pulls
  and start-up time.
- "Run an OCI registry on the host": its ObjectNode could later back a
  registry or other S3 users.

**Effort:** L
**Priority:** P4
**Depends on:** A first consumer that needs persistent volumes.

### Research eBPF observability and runtime security (Tetragon)

**What:** Survey eBPF-based tools that add process, file and syscall
visibility on top of Hubble's network view, starting with Tetragon, and
pick at most one to plan in depth.

**Why:** Hubble shows which pods talk to which. It does not show which
process in a pod opened a file, ran a binary or made a connection.
Tetragon, from the Cilium project, records those events in the kernel
and can also block them.

**Context:**
- Tetragon v1.7.1 (2026-08-25). It installs by Helm chart, so Flux owns
  it as a `components/` entry. Policies are `TracingPolicy` custom
  resources. Its events go to JSON logs, `tetra` CLI, or a metrics
  endpoint.
- Other eBPF tools to compare, all to be checked before the plan:
  Inspektor Gadget (ad hoc tracing gadgets), Parca (continuous
  profiling), Grafana Beyla (automatic HTTP and gRPC metrics and traces),
  Pixie.
- Check what the OrbStack VM kernel supports: BTF (needed by Tetragon
  and most CO-RE tools), and which program types work alongside the
  netkit datapath this cluster's Cilium uses.
- Decide where the output goes before adding a tool. The cluster has no
  log or metrics store yet (see "Plan metrics and dashboards"), so a
  first step may be CLI and UI only.
- Research first; a plan with lifecycle, resource cost and policy
  examples comes later.

**Integrates with:** Tetragon events and metrics go to the OpenTelemetry
Collector. KubeArmor overlaps on enforcement, so decide which one
enforces.

**Effort:** S
**Priority:** P4
**Depends on:** None

### Plan KubeArmor when it becomes relevant

**What:** When a trigger below applies, plan KubeArmor for runtime
enforcement: restricting which processes, files and network calls each
workload may use.

**Why:** Tetragon mainly observes, with some enforcement. KubeArmor is
built for enforcement and applies policies through Linux security
modules (AppArmor, BPF-LSM or SELinux). Today the cluster runs only
platform components, so there is nothing to confine yet.

**Context:**
- KubeArmor v1.7.5 (2026-09-11), a CNCF sandbox project. Policies are
  `KubeArmorPolicy` and `KubeArmorHostPolicy` custom resources.
- Triggers: running workloads not written here, several tenants, or a
  compliance need for runtime rules.
- Check first whether the OrbStack VM kernel enables BPF-LSM (`lsm=` on
  the kernel command line) or AppArmor, and whether OrbStack lets that
  change. Without either, KubeArmor can only audit.
- Compare with Tetragon's enforcement and with Kyverno (admission time
  only; see "Plan Kyverno"), so each tool keeps one job.

**Integrates with:** Its alerts and logs go to the OpenTelemetry
Collector. Kyverno checks resources at admission and KubeArmor at
runtime, so a workload rule lives in one of them, not both.

**Effort:** S
**Priority:** P4
**Depends on:** Research eBPF observability and runtime security
(Tetragon); a trigger above.

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

**Integrates with:** Crossplane could create the second cluster.
Telemetry decides when traffic may move to it.

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

**Integrates with:** It can cache images for every coming component, and
Crossplane provider packages, which are OCI artifacts.

**Effort:** M
**Priority:** P4
**Depends on:** Add Flux Operator and hand Cilium and Flux to Flux.

## Completed

### Prove Flux-owned upgrades with `env:e2e --from-branch`

Done on 2026-09-25 from the `test/flux-upgrade-proof` branch at
`d3203d5`, whose only change annotates the Cilium agent pods so Flux
rolls them. `mise run --yes env:e2e local --from-branch main` built a
baseline from main, switched Flux to the branch, and passed:
- fortio got 5988 of 5988 requests answered 200 over 59 s, the slowest
  in 14 ms, and the conn-disrupt connections held;
- the run ended "traffic held across the Cilium agent restart";
- the pods in `environment/local/tests/upgrade-unaffected` kept their
  UIDs, container IDs and restart counts.

Earlier attempts that day failed on host DNS stalls, not on the lane
(see "Mirror the OpenTofu providers locally"). A real version bump is
still untested: see "Test a Cilium version bump with
`env:e2e --from-branch`".

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
