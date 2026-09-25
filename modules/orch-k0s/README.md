# orch-k0s

Abstract: OpenTofu module declaring one `controller+worker` k0s node,
using the `Mirantis/k0sctl` provider's `k0sctl_config` resource. Generic
over the target host — this module has no OrbStack-specific knowledge.

## Inputs

`ssh_address`, `ssh_user`, `ssh_port`, `ssh_key_path`, `api_address`
(required, validated — see `variables.tf`), `cluster_name` (optional,
default `firmament`), `api_port` (optional, default `6443`; rendered as
`spec.api.port`), `kube_proxy_replacement` (optional, default `true`;
fixed at cluster creation: the module records it in
`terraform_data.kube_proxy_replacement_at_creation`, and a plan with a
different value fails), `drain_before_upgrade` (optional, default
`true`; rendered as the provider's `no_drain = !drain_before_upgrade`.
On one node a drain evicts every pod with nowhere to go, so single-node
clusters set `false`).
In this repo, [`environment/local`](../../environment/local/README.md)
supplies all of these by deriving them from `module.vm_orb`'s outputs;
against a non-OrbStack Ubuntu host, supply its real SSH endpoint and a
reachable API address instead.

## Outputs

`k0s_yaml` (the rendered k0sctl contract, for inspection) and `kube_yaml`
(the kubeconfig content, sensitive — the caller decides where to write
it; this module doesn't write files itself).

## Contract

`cluster.tf` is the source of truth for the cluster: k0s version,
single-node role, custom CNI, kube-proxy setting, and Pod/Service CIDRs.
There is no separate render step — `plan` is the preview; the rendered
`k0sctl.yaml` equivalent is only known after `apply` (the `k0s_yaml`
output) since the provider builds it internally during `Create`, not
during `Plan`.

k0s is pinned to `1.36.4+k0s.0` in `cluster.tf`. The provider is pinned to
`Mirantis/k0sctl` `0.0.3` in `main.tf` — the newest version actually
published to the Terraform Registry (the GitHub repo's `v0.0.4` tag
exists but was never released there).

The apply owns k0s and its managed containerd. The cluster config has no
`extensions` key: k0s installs no Helm charts, since in-cluster add-ons,
the CNI included, belong to Flux. The node stays NotReady until a CNI
runs; k0sctl waits only for the API server on a `controller+worker`
host, so the apply finishes without one.

## Reading the cluster

`mise.toml` exports `KUBECONFIG` pointing at the rendered kubeconfig, so
a bare `kubectl get nodes` works from the repo directory once your shell
has it — see the root [README](../../README.md#setup).

**k0s runs on the guest, not on your machine.** The `k0s` binary k0sctl
installs there is `-rwxr-x---`, `root:root`: it's the `k0scontroller`
systemd service's binary, not a general-purpose CLI for the ordinary
user. If you SSH into the host directly, `k0s ...` bare fails with
`Permission denied`; use `sudo k0s kubectl get nodes` (passwordless sudo
is required by `modules/os-ubuntu`'s readiness contract, so this doesn't
prompt). Neither `kubectl` nor `k0sctl` is installed on the guest — both
are operator tools that run from your machine against the guest's
exposed API.

## Commands

Run from the repo root — this module has no state or backend of its
own; see [`environment/local`](../../environment/local/README.md) for
the full task list:

| Command | Behavior |
| --- | --- |
| `mise run k0s:apply` | Apply only the cluster and kubeconfig, then wait for the node to register; Cilium and Flux come from `env:apply` |
| `mise run k0s:plan` | Plan without applying |
| `mise run k0s:verify` | Wait for every node to be Ready, using the rendered kubeconfig |
| `mise run tofu:test` | Run `tests/unit.tftest.hcl` and `tests/creation.tftest.hcl` (and every other OpenTofu suite) against rendered plans, no live host |
| `mise run k0s:test` | Run `tests/inputs.bats`, which checks that OpenTofu refuses a plan without the required inputs |
