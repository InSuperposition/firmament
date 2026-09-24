# local environment

Abstract: Composes `modules/vm-orb`, `modules/os-ubuntu` and
`modules/orch-k0s` into one applied environment with a single shared
OpenTofu state — the OrbStack machine, the readiness check that gates
provisioning it, and the k0s cluster on top of it — then bootstraps
Cilium and Flux. From then on Flux runs both from `components/`.

## Composition

```hcl
module "vm_orb"   { source = "../../modules/vm-orb" }
module "os_ubuntu" { source = "../../modules/os-ubuntu"; ssh_target = module.vm_orb.ssh_target }
module "orch_k0s"  { source = "../../modules/orch-k0s"; ...derived from module.vm_orb...; depends_on = [module.os_ubuntu] }
module "bootstrap_flux" { source = "git::...flux-operator-bootstrap.git?ref=<v0.8.0 commit>"; ... }  # bootstrap.tf
```

`orch_k0s`'s SSH connection details (`address`, `user`, `port`,
`api_address`, `cluster_name`) are all derived from `module.vm_orb`'s
outputs, not separately supplied — the modules themselves stay generic
(`orch-k0s` works against any Ubuntu host with SSH access; only this root
config knows it's talking to an OrbStack machine specifically). The
`depends_on` on `orch_k0s` means `os_ubuntu`'s readiness postconditions
must pass before k0s ever touches the host — that ordering is enforced by
OpenTofu, not by which mise task you happen to run.

k0s installs no Helm charts, so the node stays NotReady until Cilium
runs. `local.api_address` (the machine's OrbStack DNS name) and
`local.api_port` reach both k0s and Cilium's values, so k0s serves the
API where Cilium's agent connects.

## Flux

`bootstrap.tf` calls the upstream
[flux-operator-bootstrap](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap)
module, pinned by commit. Its Job installs Cilium, then Flux Operator and
the `FluxInstance`, once; from then on Flux reconciles all three from
`components/cni-cilium` and `components/gitops-flux`, through
`flux/kustomization.yaml`. The bootstrap reads each chart digest, the
values and the `FluxInstance` from those components, so both install the
same bytes, under the release names Flux adopts. Increment
`bootstrap_revision` only to rerun the Job on purpose.

The Job installs the pod network, so it runs before one exists: on the
host network, with the API address set directly, tolerating the node
that is not Ready yet.

`runtime_info` carries the values the components substitute: the API
address and port, the kube-proxy mode, the Cilium datapath and operator
replicas (derived here, since Flux substitution cannot evaluate
conditionals), the environment name and the Git branch.

`providers.tf` configures the Helm and Kubernetes providers from the
kubeconfig `orch_k0s` returns. On a fresh environment that kubeconfig is
unknown at plan time, and one apply still builds the machine, the cluster
and the bootstrap.

Flux follows a branch of the public repository, so commits reach the
cluster only after they are pushed. The tasks pass the checked-out branch
as `git_branch`; set `FIRMAMENT_GIT_BRANCH` to follow another, and on a
detached HEAD. `env:destroy` forgets the bootstrap's state before
destroying, since its objects go with the machine.

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
| `mise run env:plan` | Plan the whole environment |
| `mise run env:apply` | Apply the whole environment, then wait for Cilium, the `FluxInstance` and the Cilium HelmRelease to be ready, and the node to be Ready. It refuses a cluster whose Helm charts k0s still installs (rebuild it instead). On an existing cluster it does not wait for Flux to apply the pushed commit; `env:verify` does |
| `mise run env:destroy` | Destroy the whole environment, after a confirmation prompt (`-y` skips it) |
| `mise run orb:plan` / `orb:apply` / `orb:destroy` | `-target=module.vm_orb` only |
| `mise run ubuntu:verify` | `-target=module.os_ubuntu` only |
| `mise run k0s:plan` / `k0s:apply` | `-target=module.orch_k0s -target=local_sensitive_file.kubeconfig`; `k0s:apply` waits for the node to register, not for Cilium |
| `mise run verify` | Run every `*:verify` task below, one at a time |
| `mise run k0s:verify` | Wait for every node to be Ready, using the kubeconfig path recorded in state |
| `mise run cilium:verify` | Wait for the Cilium agent, operator, Hubble Relay and Hubble UI, using the kubeconfig path recorded in state |
| `mise run env:verify` | Run the read-only chainsaw suite in `tests/cluster` against the cluster: nodes Ready, no kube-proxy, Cilium replacing it on the netkit datapath, no k0s Charts, the `FluxInstance` and both HelmReleases Ready and owning their workloads, and the root Kustomization applied at `refs/heads/<branch>@sha1:<origin tip>` |
| `mise run env:test` | Test that the modules and components are wired together (shared API address and port, kube-proxy setting, bootstrap charts, values and runtime info) against a plan in a temporary state, with no OrbStack calls |
| `mise run cilium:conformance` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests and every flow through a Hubble Relay port-forward (`--hubble-port`, default 4245; fails if that port is taken), then remove its test workloads; a failed run keeps them for debugging (slow, manual only) |
| `mise run env:e2e` | Destroy the cluster, rebuild it from scratch, run `verify` and `cilium:conformance` against it, then destroy it again. Refuses to start unless the working tree is clean (untracked files included) and HEAD is the tip of the branch on origin, since Flux reads the pushed branch; fails if origin moves during the run. Stops at the first failure and leaves the cluster up for inspection. Asks first; about 17 minutes |
| `mise run env:e2e --from-branch <branch>` | Also test an upgrade: build the cluster from `<branch>` in a detached worktree and verify it, record the pods and containers of the workloads in `tests/upgrade-unaffected`, then apply the checked-out branch over it, run the same checks, and fail if those workloads were replaced or restarted. The baseline must already be merged into `origin/main` (its own tasks run on this machine) and must hand Cilium to Flux. Traffic continuity is not measured. Run it before merging a k0s, Cilium, Flux, Flux Operator or k0sctl provider bump |

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
$FIRMAMENT_STATE_HOME/environment/local/
```

mise sets `FIRMAMENT_STATE_HOME` to
`${XDG_STATE_HOME:-$HOME/.local/state}/firmament` unless it is already
set, and treats an empty value as unset.
