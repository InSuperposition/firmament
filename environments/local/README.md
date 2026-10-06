# local environment

Abstract: The local environment on one OrbStack machine. Three OpenTofu
roots build it in order, each from the contract file the one before it
wrote: `roots/machine-orb` (the machine and its readiness check),
`roots/kubernetes-k0s` (k0s on it) and `roots/bootstrap-flux` (Cilium and
Flux). From then on Flux runs both from `packages/`, through the Flux
build of the cluster definition `environment.yaml` names
(`clusters/singularity/flux/kustomization.yaml`). This folder holds only
what is specific to the environment: `environment.yaml`, the workloads an
upgrade must leave running (`tests/upgrade-unaffected`) and the
`mise.toml` that points kubectl at this cluster.

Flux follows a branch of the public repository, so commits reach the
cluster only after they are pushed. The tasks pass the checked-out branch
as `git_branch`; set `FIRMAMENT_GIT_BRANCH` to follow another, and on a
detached HEAD.

## Commands

Every task below takes the environment name as an optional argument,
defaulting to `local` (`mise run env:plan local`). All except `env:test`
talk to this environment's state or machine.

| Command | Behavior |
| --- | --- |
| `mise run env:doctor` | Explain why an environment task would fail, without changing anything: the environment and its worktree owner, readable state files, OrbStack, the machine, DNS from the Mac and from the machine (`host.orb.internal`, `ghcr.io`), and the API server's `/readyz`. One line per check (`ok`, `skip` with the reason, or `FAIL` with the next command); exits 1 on any failure. "No route to host" from the API server is reported as missing macOS Local Network access, which background agent sessions can lack. A `.orb.local` name that times out while the machine's own address answers is reported with `orb restart`. A missing cluster is `skip`, since `env:apply` creates it |
| `mise run env:plan` | Plan the machine root, then the Kubernetes root once a machine is recorded, then the bootstrap root once a cluster is recorded |
| `mise run env:apply` | Apply the machine, Kubernetes and bootstrap roots in order, then wait for Cilium, the `FluxInstance` and the Cilium HelmRelease to be ready, and the node to be Ready. It refuses a cluster whose Helm charts k0s still installs (rebuild it instead). On an existing cluster it does not wait for Flux to apply the pushed commit; `env:verify` does |
| `mise run env:destroy` | Destroy the Kubernetes root, then the machine root, after a confirmation prompt (`-y` skips it); the bootstrap root's objects go with the machine |
| `mise run orb:plan` / `orb:apply` | Plan or apply the machine root: the OrbStack machine, its readiness check and the `machine-hosts` contract |
| `mise run orb:destroy` | Destroy the Kubernetes root, then the machine root: k0s cannot outlive its machine |
| `mise run ubuntu:verify` | Plan the machine root, which runs the Ubuntu readiness probe over SSH |
| `mise run k0s:plan` / `k0s:apply` | Plan or apply the Kubernetes root against the `machine-hosts` contract; `k0s:apply` waits for the node to register, not for Cilium |
| `mise run verify [--only <packages> \| --changed]` | Run every `*:verify` task below, one at a time, `env:verify` first so the others check what the pushed commit deploys. `--only cilium` or `--only flux` skips the other packages' suites and tasks; the environment's own checks (the cluster's own suite, `k0s:verify`, `ubuntu:verify`) always run. `--changed` chooses the packages the branch changed since it left `origin/main`: a change under `packages/<name>/` selects that package, Markdown selects nothing, any other change selects every package |
| `mise run k0s:verify` | Wait for every node to be Ready, using the kubeconfig path in the `cluster-access` contract |
| `mise run cilium:verify` | Wait until the `cilium` release runs the values in the `cilium-values` ConfigMap (`helm get values`) and the agent DaemonSet has rolled out, then for the Cilium agent, operator, Hubble Relay and Hubble UI, using the kubeconfig path in the `cluster-access` contract |
| `mise run env:verify` | Run the read-only chainsaw suites against the cluster: the cluster's `tests/cluster` (nodes Ready, no kube-proxy, no k0s Charts), then `tests/cluster` of each package its Flux build lists: `cilium` (Cilium running the kube-proxy mode and datapath `runtime_info` sets) and `flux` (the `FluxInstance` and both HelmReleases Ready and owning their workloads, and the root Kustomization applied at `refs/heads/<branch>@sha1:<origin tip>`) |
| `mise run env:test` | Test each root and the contracts between them (shared API address and port, kube-proxy setting, bootstrap charts, values and runtime info) against plans in a temporary state, with no OrbStack calls |
| `mise run conformance [--only <packages> \| --changed]` | Run every `*:conformance` task, passing `--only` on. With `--only`, each task runs only the tests the chosen packages list, one regular expression per line, in `packages/<name>/tests/conformance`: `cilium` lists the whole suite, `flux` lists none, so `--only flux` runs nothing |
| `mise run cilium:conformance` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests, with Hubble flow logs for failed actions through a Relay port-forward (`--hubble-port`, default 4245; fails if that port is taken or Relay is unreachable; flow validation is disabled until cilium-cli can match these flows, see [BUGS.md](../../packages/cilium/BUGS.md#flow-validation-never-matches-reverse-nated-service-replies)), then remove its test workloads; a failed run keeps them for debugging (slow, manual only) |
| `mise run cilium:traffic-start` | Start traffic for `cilium:traffic-check` to measure: cilium-cli conn-disrupt connections held open, and fortio in the `traffic-probe` namespace opening 100 new connections a second through a ClusterIP Service. Records the fortio run and the Cilium agent pods in the environment's state directory, replacing any earlier run. `FIRMAMENT_FORTIO_START_TIMEOUT` (whole seconds, default 30) bounds the wait for fortio to start sending |
| `mise run cilium:traffic-check` | Measure the traffic `cilium:traffic-start` began: fails when a conn-disrupt connection broke, any fortio request failed, or fortio sent under 90% of the requested rate, prints the slowest request, and ends with whether the traffic crossed a Cilium agent restart. Removes the test workloads when it passes; a failed check keeps them for inspection |
| `mise run env:e2e` | Destroy the cluster, rebuild it from scratch, run `verify` and `cilium:conformance` against it, then destroy it again. Refuses to start unless the working tree is clean (untracked files included) and HEAD is the tip of the branch on origin, since Flux reads the pushed branch; fails if origin moves during the run. Stops at the first failure and leaves the cluster up for inspection. A passing run ends with the time each step took and the change since the last passing run, which it keeps in the environment's state directory; the times are reported, never judged. Asks first |
| `mise run env:e2e --from-branch <branch>` | Also test an upgrade: build the cluster from `<branch>` in a detached worktree and verify it, record the pods and containers of the workloads in `tests/upgrade-unaffected`, then apply the checked-out branch over it, run the same checks, and fail if those workloads were replaced or restarted. The baseline must already be merged into `origin/main` (its own tasks run on this machine) and must hand Cilium to Flux. Traffic runs through the switch: `cilium:traffic-start` starts it after the baseline verifies and `cilium:traffic-check` measures it after the upgrade verifies, and the run's final line says whether the traffic crossed a Cilium agent restart. Run it before merging a k0s, Cilium, Flux, Flux Operator or k0sctl provider bump |

## Roots and contracts

Each root has its own state file and hands the next one a contract file
in the environment's state directory: `machine-hosts.yaml`, then
`cluster-access.yaml`. Tasks that only read the cluster (`*:verify`,
`env:doctor`, the UIs) read the contracts and run no OpenTofu at all. A
root deletes its contract when it is destroyed, so a missing file means
nothing is recorded there. Each root's README describes its contract.

## State

The state files (`machine-orb.tfstate`, `kubernetes-k0s.tfstate`,
`bootstrap-flux.tfstate`), the contracts and the kubeconfig live outside
Git at:

```text
$FIRMAMENT_STATE_HOME/environment/local/
```

mise sets `FIRMAMENT_STATE_HOME` to
`${XDG_STATE_HOME:-$HOME/.local/state}/firmament` unless it is already
set, and treats an empty value as unset.
