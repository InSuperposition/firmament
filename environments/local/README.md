# local environment

Abstract: `environment.yaml` describes the environment as data: one
OrbStack machine per cluster (today one cluster, `workload`, on machine
`local-workload`), the budget the machines must fit, and the mesh
allocations. The `orb:apply` task creates the machines with the `orb` CLI,
checks each new one is ready for k0s, and writes their `machine-hosts` file
to the state directory. This OpenTofu root reads that file and installs
k0s with `modules/orch-k0s`. A second OpenTofu root, `bootstrap/`, with its own state, then
bootstraps Cilium and Flux into that cluster. From then on Flux runs both
from `packages/`.

## Composition

```text
environment.yaml --orb:apply--> OrbStack machines + machine-hosts.yaml (state directory)
machine-hosts.yaml --this root--> module "orch_k0s" (k0s) + admin.kubeconfig
```

```hcl
# bootstrap/, applied after the root above, with its own state
data "terraform_remote_state" "environment" { ... }  # kubeconfig_path and runtime_info
module "bootstrap_flux" { source = "git::...flux-operator-bootstrap.git?ref=<v0.8.0 commit>"; ... }
```

`orch_k0s`'s SSH connection details (`address`, `user`, `port`,
`cluster_name`) come from the `machine-hosts` file (the machine-hosts
contract in `contracts/`), so `orch-k0s` stays generic: it works against any
Ubuntu host with SSH access. OrbStack itself is the record of which
machines exist; there is no OpenTofu state for them. `env:apply` runs
`orb:apply` first, and `orb:apply` runs the readiness check on every machine
it creates, so k0s never touches a host that failed it. `machine-hosts`
records each machine's IP; the API address is still the machine's
`.orb.local` name.

k0s installs no Helm charts, so the node stays NotReady until Cilium
runs. `local.api_address` (the machine's OrbStack DNS name) and
`local.api_port` reach both k0s and Cilium's values, so k0s serves the
API where Cilium's agent connects.

## Flux

`bootstrap/bootstrap.tf` calls the upstream
[flux-operator-bootstrap](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap)
module, pinned by commit. Its Job installs Cilium, then Flux Operator and
the `FluxInstance`, once; from then on Flux reconciles all three from
`packages/cni-cilium` and `packages/gitops-flux`, through
`flux/kustomization.yaml`. The bootstrap reads each chart digest, the
values and the `FluxInstance` from those packages, so both install the
same bytes, under the release names Flux adopts. Increment
`bootstrap_revision` only to rerun the Job on purpose.

The Job installs the pod network, so it runs before one exists: on the
host network, with the API address set directly, tolerating the node
that is not Ready yet.

`runtime_info` carries the values the packages substitute: the API
address and port, the kube-proxy mode, the Cilium datapath and operator
replicas (derived here, since Flux substitution cannot evaluate
conditionals), the environment name and the Git branch. The same values
are the `runtime_info` output: `env:verify` passes them to the chainsaw
suites as `$values`, so a package suite checks the cluster against what
this environment asked for rather than fixed values.

The bootstrap is its own root, applied after this one: the Kubernetes
provider docs warn against configuring the provider from resources created
in the same apply. `bootstrap/main.tf` reads the `kubeconfig_path` and
`runtime_info` outputs from this root's state, and its state,
`bootstrap.tfstate`, sits next to this root's. `env:apply` applies both
roots; `env:plan` plans the bootstrap once a cluster is recorded.

Flux follows a branch of the public repository, so commits reach the
cluster only after they are pushed. The tasks pass the checked-out branch
as `git_branch`; set `FIRMAMENT_GIT_BRANCH` to follow another, and on a
detached HEAD.

`env:destroy` and `orb:destroy` destroy only this root. The bootstrap's
objects live in the cluster and go with the machine; its state keeps them
until the next apply, whose refresh finds them gone and plans them again.
So an interrupted destroy needs no state restore. An environment applied
before the bootstrap had its own root is moved over by the next task that
initializes it (`tofu state mv`), keeping the old state as
`terraform.tfstate.before-bootstrap-root`.

## Cilium replaces kube-proxy

This environment always runs without kube-proxy: `main.tf` sets
`kube_proxy_replacement = true` for both k0s (`kubeProxy.disabled`) and
Cilium (`kubeProxyReplacement`), which also selects Cilium's netkit pod
datapath with BPF masquerading. It is not a variable, because no
environment runs kube-proxy. `modules/orch-k0s` and the Cilium values
still accept `false` (veth with iptables masquerading, kube-proxy run by
k0s), and `modules/orch-k0s` refuses to change the value on an existing
cluster, since Cilium documents no live migration between the two modes
for a single node.

`drain_before_upgrade = false`: on one node a drain before a k0s upgrade
would evict every pod with nowhere to go.

## Commands

Every task below takes the environment name as an optional argument,
defaulting to `local` (`mise run env:plan local`). All except `env:test`
talk to this environment's state or machine.

k0sctl reaches the machine with the SSH key OrbStack creates,
`~/.orbstack/ssh/id_ed25519`. To use another key, set
`TF_VAR_orbstack_ssh_key_path` to its absolute path.

| Command | Behavior |
| --- | --- |
| `mise run env:doctor` | Explain why an environment task would fail, without changing anything: the environment and its worktree owner, readable state files, OrbStack, the machine, DNS from the Mac and from the machine (`host.orb.internal`, `ghcr.io`), and the API server's `/readyz`. One line per check (`ok`, `skip` with the reason, or `FAIL` with the next command); exits 1 on any failure. "No route to host" from the API server is reported as missing macOS Local Network access, which background agent sessions can lack. A `.orb.local` name that times out while the machine's own address answers is reported with `orb restart`. A missing cluster is `skip`, since `env:apply` creates it |
| `mise run env:plan` | Show the machine plan, then plan k0s once the machines are recorded, then the bootstrap root once a cluster is recorded |
| `mise run env:apply` | Create the machines (`orb:apply`), apply k0s, then the bootstrap root, then wait for Cilium, the `FluxInstance` and the Cilium HelmRelease to be ready, and the node to be Ready. It refuses a cluster whose Helm charts k0s still installs (rebuild it instead). On an existing cluster it does not wait for Flux to apply the pushed commit; `env:verify` does |
| `mise run env:destroy` | Destroy the cluster, then delete the machines, after a confirmation prompt (`-y` skips it) |
| `mise run orb:plan` / `orb:apply` | Show, or make, the machines `environment.yaml` lists: create a missing one (with its memory, CPU and disk limits, then the readiness check), keep one whose limits match, and refuse one whose limits differ. `orb:apply` first checks the machines fit OrbStack: their memory summed within OrbStack's memory, and each machine's CPUs within OrbStack's CPUs (CPUs may be shared). It then writes `machine-hosts.yaml` to the state directory |
| `mise run orb:destroy` | Destroy the cluster on the machines, then delete the machines `environment.yaml` lists, after a confirmation prompt; machines it does not list are never touched |
| `mise run orb:inspect` | Print the native metadata of each machine |
| `mise run orb:verify` | Check each machine runs with its limits: memory and CPUs from the machine's own cgroup (`memory.max`, `cpu.max`; `free` and `nproc` show the shared OrbStack VM), disk from OrbStack's configuration |
| `mise run ubuntu:verify` | Check each machine is ready for k0s (Ubuntu 26.04, systemd, cgroup v2, kernel BTF, passwordless sudo, curl, systemctl), naming each requirement a machine misses |
| `mise run k0s:plan` / `k0s:apply` | `-target=module.orch_k0s -target=local_sensitive_file.kubeconfig`; `k0s:apply` waits for the node to register, not for Cilium |
| `mise run verify [--only <modules> \| --changed]` | Run every `*:verify` task below, one at a time, `env:verify` first so the others check what the pushed commit deploys. `--only cilium` or `--only flux` skips the other modules' suites and tasks; the environment's own checks (`env:verify`'s own suite, `k0s:verify`, `ubuntu:verify`) always run. `--changed` chooses the modules the branch changed since it left `origin/main`: a change under `packages/<name>/` selects that module, Markdown selects nothing, any other change selects every module |
| `mise run k0s:verify` | Wait for every node to be Ready, using the kubeconfig path recorded in state |
| `mise run cilium:verify` | Wait until the `cilium` release runs the values in the `cilium-values` ConfigMap (`helm get values`) and the agent DaemonSet has rolled out, then for the Cilium agent, operator, Hubble Relay and Hubble UI, using the kubeconfig path recorded in state |
| `mise run env:verify` | Run the read-only chainsaw suites against the cluster: this environment's `tests/cluster` (nodes Ready, no kube-proxy, no k0s Charts), then `tests/cluster` of each package `flux/kustomization.yaml` lists: `cni-cilium` (Cilium running the kube-proxy mode and datapath `runtime_info` sets) and `gitops-flux` (the `FluxInstance` and both HelmReleases Ready and owning their workloads, and the root Kustomization applied at `refs/heads/<branch>@sha1:<origin tip>`) |
| `mise run env:test` | Test that the modules and packages are wired together (shared API address and port, kube-proxy setting, bootstrap charts, values and runtime info) against a plan in a temporary state, with no OrbStack calls |
| `mise run conformance [--only <modules> \| --changed]` | Run every `*:conformance` task, passing `--only` on. With `--only`, each task runs only the tests the chosen modules list, one regular expression per line, in `packages/<name>/tests/conformance`: `cni-cilium` lists the whole suite, `gitops-flux` lists none, so `--only flux` runs nothing |
| `mise run cilium:conformance` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests, with Hubble flow logs for failed actions through a Relay port-forward (`--hubble-port`, default 4245; fails if that port is taken or Relay is unreachable; flow validation is disabled until cilium-cli can match these flows, see [BUGS.md](../../packages/cni-cilium/BUGS.md#flow-validation-never-matches-reverse-nated-service-replies)), then remove its test workloads; a failed run keeps them for debugging (slow, manual only) |
| `mise run cilium:traffic-start` | Start traffic for `cilium:traffic-check` to measure: cilium-cli conn-disrupt connections held open, and fortio in the `traffic-probe` namespace opening 100 new connections a second through a ClusterIP Service. Records the fortio run and the Cilium agent pods in the environment's state directory, replacing any earlier run. `FIRMAMENT_FORTIO_START_TIMEOUT` (whole seconds, default 30) bounds the wait for fortio to start sending |
| `mise run cilium:traffic-check` | Measure the traffic `cilium:traffic-start` began: fails when a conn-disrupt connection broke, any fortio request failed, or fortio sent under 90% of the requested rate, prints the slowest request, and ends with whether the traffic crossed a Cilium agent restart. Removes the test workloads when it passes; a failed check keeps them for inspection |
| `mise run env:e2e` | Destroy the cluster, rebuild it from scratch, run `verify` and `cilium:conformance` against it, then destroy it again. Refuses to start unless the working tree is clean (untracked files included) and HEAD is the tip of the branch on origin, since Flux reads the pushed branch; fails if origin moves during the run. Stops at the first failure and leaves the cluster up for inspection. A passing run ends with the time each step took and the change since the last passing run, which it keeps in the environment's state directory; the times are reported, never judged. Asks first |
| `mise run env:e2e --from-branch <branch>` | Also test an upgrade: build the cluster from `<branch>` in a detached worktree and verify it, record the pods and containers of the workloads in `tests/upgrade-unaffected`, then apply the checked-out branch over it, run the same checks, and fail if those workloads were replaced or restarted. The baseline must already be merged into `origin/main` (its own tasks run on this machine) and must hand Cilium to Flux. Traffic runs through the switch: `cilium:traffic-start` starts it after the baseline verifies and `cilium:traffic-check` measures it after the upgrade verifies, and the run's final line says whether the traffic crossed a Cilium agent restart. Run it before merging a k0s, Cilium, Flux, Flux Operator or k0sctl provider bump |

## What `-target` does and doesn't isolate

The per-module tasks above run `tofu ... -target=module.X` against the
same shared state, not a separate state per module. OpenTofu always
expands `-target` to include what that module actually depends on:

- `k0s:apply` on a completely fresh environment creates the VM and runs
  the readiness check too, not just k0s — `orch_k0s` depends on both.
- `k0s:apply` and `k0s:plan` also target
  `local_sensitive_file.kubeconfig`. Without it, a k0s change would leave
  the kubeconfig on disk stale.
- `orb:destroy` destroys `orch_k0s`'s cluster first, then the VM — because
  the cluster can't exist without the machine it runs on. This is the
  fix for the old design's failure mode, where deleting the VM separately
  left the k0s stage's state silently pointing at a host that no longer
  existed.

OpenTofu prints a `Resource targeting is in effect` warning on every
`-target` run. That's expected — it's the standard warning for exactly
this pattern, not an error.

## State

The shared backend and the rendered kubeconfig live outside Git at:

```text
$FIRMAMENT_STATE_HOME/environments/local/
```

mise sets `FIRMAMENT_STATE_HOME` to
`${XDG_STATE_HOME:-$HOME/.local/state}/firmament` unless it is already
set, and treats an empty value as unset.
