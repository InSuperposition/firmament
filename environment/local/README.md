# local environment

Abstract: Composes `modules/vm-orb`, `modules/os-ubuntu`,
`modules/cni-cilium`, and `modules/orch-k0s` into one applied environment
with a single shared OpenTofu state — the OrbStack machine, the readiness
check that gates provisioning it, and the k0s cluster on top of it with
Cilium and Hubble as its network.

## Composition

```hcl
module "vm_orb"   { source = "../../modules/vm-orb" }
module "os_ubuntu" { source = "../../modules/os-ubuntu"; ssh_target = module.vm_orb.ssh_target }
module "cni_cilium" { source = "../../modules/cni-cilium"; api_host = local.api_address; ... }
module "orch_k0s"  { source = "../../modules/orch-k0s"; ...derived from module.vm_orb...; helm_charts = [module.cni_cilium.helm_chart]; depends_on = [module.os_ubuntu] }
```

`orch_k0s`'s SSH connection details (`address`, `user`, `port`,
`api_address`, `cluster_name`) are all derived from `module.vm_orb`'s
outputs, not separately supplied — the modules themselves stay generic
(`orch-k0s` works against any Ubuntu host with SSH access; only this root
config knows it's talking to an OrbStack machine specifically). The
`depends_on` on `orch_k0s` means `os_ubuntu`'s readiness postconditions
must pass before k0s ever touches the host — that ordering is enforced by
OpenTofu, not by which mise task you happen to run.

`cni_cilium` renders the Cilium chart declaration and `orch_k0s` hands it
to k0s's built-in Helm installer (`spec.extensions.helm`). k0s installs
Cilium inside the cluster during bring-up, so this config needs no Helm
or Kubernetes provider and no kubeconfig at plan time. Both modules read
`local.api_address` (the machine's OrbStack DNS name) and `local.api_port`,
so k0s serves the API where Cilium's agent connects; `cni_cilium` reads
no `orch_k0s` output, since that edge would form a cycle.

## Kube-proxy replacement is fixed at creation

`kube_proxy_replacement` (default `true`) sets both k0s's
`kubeProxy.disabled` and Cilium's `kubeProxyReplacement`. Choose it
before the first `local:bootstrap`. Cilium documents no live migration
between the two modes for a single node (the only path is
[per-node configuration](https://docs.cilium.io/en/stable/configuration/per-node-config/)),
so changing it on a running cluster means `teardown:local` then
`local:bootstrap`. It also selects Cilium's pod datapath: netkit with
BPF masquerading when `true`, veth with iptables masquerading when
`false`, since netkit requires kube-proxy replacement.

`modules/orch-k0s` records the value when the cluster is created. Any
plan with a different value fails with "kube_proxy_replacement is fixed
at cluster creation" before anything reaches the cluster. On a cluster
bootstrapped with `false`, pass the same `TF_VAR_kube_proxy_replacement`
to every later `plan`, `k0s:*` or `local:bootstrap` run:

```sh
mise run teardown:local
TF_VAR_kube_proxy_replacement=false mise run local:bootstrap
```

Removing Cilium from `helm_charts` makes k0s uninstall it, which takes the
cluster network down with it.

## Commands

| Command | Behavior |
| --- | --- |
| `mise run plan` | Plan the whole environment |
| `mise run local:bootstrap` | Apply the whole environment, then wait for the node to be Ready and Cilium to report healthy |
| `mise run teardown:local` | Destroy the whole environment |
| `mise run orb:dry-run` / `orb:create` / `orb:delete` | `-target=module.vm_orb` only |
| `mise run ubuntu:check` | `-target=module.os_ubuntu` only |
| `mise run k0s:dry-run` / `k0s:apply` | `-target=module.orch_k0s -target=local_sensitive_file.kubeconfig`, which includes the Cilium chart |
| `mise run k0s:verify` | Wait for every node to be Ready, no Tofu involved |
| `mise run cilium:status` | Wait for the Cilium agent, operator, Hubble Relay and Hubble UI, no Tofu involved |
| `mise run env:test` | Test that the modules are wired together (shared API address and port, kube-proxy setting, Cilium chart) against a plan in a temporary state, with no OrbStack calls |
| `mise run cilium:connectivity` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests (slow, manual only) |

## What `-target` does and doesn't isolate

The per-module tasks above run `tofu ... -target=module.X` against the
same shared state, not a separate state per module. OpenTofu always
expands `-target` to include what that module actually depends on:

- `k0s:apply` on a completely fresh environment creates the VM and runs
  the readiness check too, not just k0s — `orch_k0s` depends on both.
  It also renders `cni_cilium`, because `orch_k0s` reads its chart.
- `k0s:apply` and `k0s:dry-run` also target
  `local_sensitive_file.kubeconfig`. Without it, a k0s change would leave
  the kubeconfig on disk stale.
- `orb:delete` destroys `orch_k0s`'s cluster first, then the VM — because
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
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environment/local/
```
