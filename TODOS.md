# TODOS

An item lives here only while it is open. When it is completed or dropped, move it to a new file under `.plan/archive/todos/` (named after the item in kebab case, such as `check-flux-depends-on-offline.md`) and remove it from this file. There is no "Completed" section here.

What belongs here: a gap with a known end state. A limit of existing code belongs in the README of that code, and so does a procedure that repeats (such as a version upgrade).

Priority: P2 bites the local setup today; P3 is cleanup, or waits for the trigger named in the item; P4 is undecided.

## Infrastructure

### Require a cluster suite or an explicit exemption for each deployed package

**What:** Make `layout:lint` (or a sibling check) fail when a deployed Flux package has no `tests/cluster` suite and no recorded exemption.

**Why:** `cluster_suites` in `.mise/lib.sh` skips a deployed package without a suite silently (the test "skips a deployed package without a suite and a package the environment does not deploy" in `.mise/tests/lib.bats` pins that). A package added without a suite is never checked on a live cluster.

**Pros:** closes the silent gap. **Cons:** needs an exemption format, and only Flux packages should need a suite.

**Context:** every deployed package has a suite except `gateway-api` (manifest-only), which the cluster's own suite covers through the Gateway API Kustomizations. The package kinds are in `contracts/layout/layout.yaml`.

**Effort:** M
**Priority:** P3
**Depends on:** nothing

### Exclude two runs from one checkout around the k0sctl edge

**What:** Add a lock around the environment apply and destroy tasks so two runs from the same checkout cannot interleave.

**Why:** `claim_environment` refuses only a different worktree, and OpenTofu's state lock covers one command, not the render, `k0sctl apply` and publish sequence. An apply racing a destroy can remove the machine while `k0sctl` is mid-run.

**Context:** `claim_environment` in `.mise/lib.sh` writes the owning worktree to `$state/owner`. The repo has no lock pattern; macOS has no `flock`, so the work is a lock directory with stale-lock handling, taken by `env:apply`, `k0s:apply` and both destroy tasks.

**Effort:** M
**Priority:** P2
**Depends on:** nothing

### Manage the GitHub repository settings as code

**What:** Declare branch protection, Actions permissions and package visibility in an OpenTofu root with the GitHub provider, so the settings that gate delivery are reviewed and recorded like the rest of the repository.

**Why:** Flux verifies artifacts signed by the publish workflow, so the Git branch and the workflow's permissions are part of the trust root. A loosened branch rule or a broader token permission is visible only on GitHub's settings page and would pass every offline check. This item is also the only place that records that assumption.

**Context:** The stack has no GitHub provider and no token held for one, so start by deciding where that token lives (the secrets rule keeps it out of Git and OpenTofu state), then check what the provider can manage. The `ghcr.io/insuperposition/firmament` package is public today (an anonymous `flux pull artifact` works); who may push a branch is the real control over what Flux accepts. The OpenTofu GitHub provider v6.13.0 offers `github_repository_ruleset` and `sha_pinning_required`, authenticated through `gh auth token`.

**Effort:** M
**Priority:** P3
**Depends on:** nothing

### Validate Flux manifests with flux-schema 0.15.0 directly

**What:** Pin `flux-schema` 0.15.0, call `flux-schema validate <dir> --envsubst-file .mise/flux-test-values.env --envsubst-strict --schema-location .mise/flux-schemas` from `flux:lint` and `flux:schemas`, then delete `render_flux_build` and `flux_test_values` from `.mise/lib.sh`.

**Why:** The `kubectl kustomize | flux envsubst | flux-schema` pipe in `lib.sh` is code the tool now covers itself. It is cleanup, not needed to deliver or verify the signed artifact.

**Context:** `mise.toml` pins 0.13.0; 0.15.0 is listed, and `mise ls-remote` warns that `minimum_release_age` hides one newer release, so lock it only once mise shows it. Check first that 0.15.0 leaves `${git_commit}` substituted and keeps any template marker intact.

**Effort:** S
**Priority:** P3
**Depends on:** nothing

### Lint GitHub workflows with zizmor

**What:** Pin `zizmor` in `mise.toml` and add a `workflow:lint` task that runs it offline from `mise run check`.

**Why:** `publish.yaml` is the only workflow in the repository and holds `id-token: write`. A linter checks it for unpinned actions and risky triggers.

**Context:** `mise.toml` records a SLSA signer identity for the tools that publish provenance (`flux2`, `chainsaw`); if `zizmor` publishes none, `mise lock` may refuse it, and the same signer fields apply.

**Effort:** S
**Priority:** P3
**Depends on:** nothing

## Tenancy

### Run the first database for a tenant (CloudNativePG)

**What:** Add the `cloudnative-pg` operator as a platform chart package and a `Cluster` in the tenant's namespace, with storage, authenticated TLS and least-privilege checks.

**Why:** `cv`, the only tenant, is a static site and needs no database. A tenant that does would need these things, found when the database was first scoped (2026-10-09): a StorageClass (none exists; OpenBao writes to a hostPath folder), `sslmode=verify-full` against the cluster CA with a wrong-CA rejection test, a dedicated app ServiceAccount with token automount off and a `kubectl auth can-i` check for the database identity, the 9443 webhook (`failurePolicy: Fail`) needing the konnectivity-agent allow in any policy mode, probe `host_ports` 8000 and 44100, `depends_on` so the operator is Ready before the `Cluster`, and `api_server_clients` so only database pods reach the API server.

**Context:** CloudNativePG creates and manages its own per-instance PVCs and does not use StatefulSets, so decide the StorageClass against that model; the OpenEBS `localpv-provisioner` OCI chart (`ghcr.io/openebs/charts/localpv-provisioner`) is the resolved candidate, re-resolve the pin first. Resolved chart: `ghcr.io/cloudnative-pg/charts/cloudnative-pg` 0.29.1, operator 1.30.1. Instance pods carry `cnpg.io/cluster`; ports: operator webhook 9443, instance status 8000, PostgreSQL 5432. `inputs.cue` allows one provider per capability per cluster, so a second database needs that rule revisited. Confirm the read-write Service name and the keys of the generated `<cluster>-app` Secret. Trigger: a tenant that needs a database.

**Effort:** L
**Priority:** P3
**Depends on:** a tenant that needs a database

### Bind tenant administrators and select workloads inside a namespace

**What:** Turn `administrators` into Roles and RoleBindings in the tenant's namespaces, and add workload selectors to `provides`/`requires` so a rule can name pods, not only namespaces.

**Why:** `administrators` is read by no module (only the schema and samples mention it), so tenant isolation is network policy alone; and policy peers are whole namespaces, so an unrelated pod in the same namespace is as trusted as the app.

**Context:** Trigger: a second person, or a second workload in a tenant namespace.

**Effort:** M
**Priority:** P3
**Depends on:** a second person or workload

### Serve the Gateway over TLS

**What:** An HTTPS listener on the platform Gateway with a certificate cert-manager issues, and a redirect from the HTTP listener.

**Why:** The Gateway serves plain HTTP on the node, which is acceptable on the local machine only. Anything beyond it sends requests and cookies in the clear.

**Context:** cert-manager and its OpenBao-backed issuer exist. The Gateway needs a `certificateRefs` Secret in `kube-system`, a name to put on the certificate (the local environment has none), and a route that matches the host. Trigger: an environment other than the local machine.

**Effort:** M
**Priority:** P3
**Depends on:** a host name for the site

### Give the Gateway an address of its own

**What:** Replace host-network mode with a Gateway Service that gets its address from Cilium LB-IPAM, announced by L2 announcements or BGP.

**Why:** Host-network mode makes Envoy listen on the node's own address and a port above 1023. A second Gateway or listener competes for node ports, and the address is the node's.

**Context:** `packages/cilium/README.md` lists the limits. Trigger: a second cluster, a real network, or a need for port 80 or 443. Changes `gatewayAPI.hostNetwork` in `clusters/singularity/gateway/cilium-values-gateway.yaml`. If a second node arrives first, every node listens on the port while the Gateway reports one address: pin Envoy with the Cilium chart's node selector for host-network Envoy (`gatewayAPI.hostNetwork.nodes.matchLabels` in 1.20; check the chart first) and decide which address `gateway:verify` and the doctor use.

**Effort:** M
**Priority:** P3
**Depends on:** a network that can announce addresses

### Declare a tenant's route in its package

**What:** A `routes` field in `package.yaml` that renders the HTTPRoute and adds the namespace to the Gateway's `allowedRoutes`.

**Why:** The `cv` route and the Gateway's namespace selector are platform YAML in `clusters/singularity/gateway/`. A tenant package declares its pod ports (`ingress_ports`) but not its route, so adding a site means editing two places.

**Context:** One tenant today, so hand-written YAML is the smaller part. Trigger: a second route.

**Effort:** M
**Priority:** P3
**Depends on:** a second routed tenant

### Probe egress of a namespace no binding names

**What:** In `tenant:verify`, start a listener in `default` and connect to it from the pod in the unbound `test-retained-*` namespace; expect a blocked connection and a DROPPED Hubble flow from that pod.

**Why:** `tenant-default-deny` denies both directions, but `tenant:verify` probes only incoming traffic to the unbound namespace. An egress hole for namespaces made by hand or left behind by a removed binding would pass every current check. The README's guarantee table lists this as not shown.

**Context:** `.mise/tasks/tenant/verify.sh` (the unbound-namespace phase) and `.mise/lib-probe.sh` (`connect_probe`, `expect_flow`). Bound tenant pods already have egress probes in `network-policy:verify`. Trigger: a second tenant or a real unbinding.

**Effort:** S
**Priority:** P3
**Depends on:** a second tenant or a real unbinding

### Break each tenant guarantee on purpose on a live cluster

**What:** Prove on real clusters that `tenant:verify` fails when each guarantee is broken: set `wrong_subject` in `.mise/tasks/tenant/verify.sh` to the real `cv` identity; point `.mise/tenant/unsigned-chart.yaml` at the signed `cv` digest; suspend the owning Flux Kustomization, delete `CiliumClusterwideNetworkPolicy tenant-default-deny`, and run the task. Each run must fail. A `--break` mode of `mise run tour` that does the same in front of an audience belongs to this item.

**Why:** The stub tests inject results (`TV_FAIL`, `NP_NO_FLOW`, `HUBBLE_FAULT`); they show the script reacts, not that Flux or Cilium produce those results when a boundary breaks. A live run on 2026-10-13 found `expect_flow` passing on a failed Hubble exec, the kind of fault this would catch earlier.

**Context:** Cost, approximate: about 10 minutes of machine time per run on its own `env:apply` cluster (apply about 7.5 min, `tenant:verify` about 1 to 3.5 min, destroy 1 to 2 min), so about 30 minutes for three runs; about 20 minutes if one cluster is reused and each mutation is undone in place. Developer attention, approximate: 45 to 60 minutes for three separate runs (edits, waits, cleanup), 30 to 40 minutes for the shared cluster. Never run on the `env:e2e` cluster. Trigger to decide: a Flux, Cilium or `tenant:verify` change that makes live behavior unclear, or another check found passing for the wrong reason.

**Effort:** M
**Priority:** P4
**Depends on:** nothing
