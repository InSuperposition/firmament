# local environment

Abstract: Composes `modules/vm-orb`, `modules/os-ubuntu`, and
`modules/orch-k0s` into one applied environment with a single shared
OpenTofu state — the OrbStack machine, the readiness check that gates
provisioning it, and the k0s cluster on top of it.

## Composition

```hcl
module "vm_orb"   { source = "../../modules/vm-orb" }
module "os_ubuntu" { source = "../../modules/os-ubuntu"; ssh_target = module.vm_orb.ssh_target }
module "orch_k0s"  { source = "../../modules/orch-k0s"; ...derived from module.vm_orb...; depends_on = [module.os_ubuntu] }
```

`orch_k0s`'s SSH connection details (`address`, `user`, `port`,
`api_address`, `cluster_name`) are all derived from `module.vm_orb`'s
outputs, not separately supplied — the modules themselves stay generic
(`orch-k0s` works against any Ubuntu host with SSH access; only this root
config knows it's talking to an OrbStack machine specifically). The
`depends_on` on `orch_k0s` means `os_ubuntu`'s readiness postconditions
must pass before k0s ever touches the host — that ordering is enforced by
OpenTofu, not by which mise task you happen to run.

## Commands

| Command | Behavior |
| --- | --- |
| `mise run plan` | Plan the whole environment |
| `mise run bootstrap:local` | Apply the whole environment, then print node status |
| `mise run teardown:local` | Destroy the whole environment |
| `mise run orb:dry-run` / `orb:create` / `orb:delete` | `-target=module.vm_orb` only |
| `mise run ubuntu:check` | `-target=module.os_ubuntu` only |
| `mise run k0s:dry-run` / `k0s:apply` | `-target=module.orch_k0s` only |
| `mise run k0s:test` | `kubectl get nodes` against the rendered kubeconfig, no Tofu involved |

## What `-target` does and doesn't isolate

The per-module tasks above run `tofu ... -target=module.X` against the
same shared state, not a separate state per module. OpenTofu always
expands `-target` to include what that module actually depends on:

- `k0s:apply` on a completely fresh environment creates the VM and runs
  the readiness check too, not just k0s — `orch_k0s` depends on both.
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
