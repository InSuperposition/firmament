# orch-k0s

Abstract: OpenTofu module declaring one `controller+worker` k0s node,
using the `Mirantis/k0sctl` provider's `k0sctl_config` resource. Generic
over the target host — this module has no OrbStack-specific knowledge.

## Inputs

`ssh_address`, `ssh_user`, `ssh_port`, `ssh_key_path`, `api_address`
(required, validated — see `variables.tf`), `cluster_name` (optional,
default `firmament`), `kube_proxy_replacement` (optional, default `true`;
fixed at cluster creation), `helm_charts` (optional, default `[]`; each
item is a `repository` and a `chart`, as `modules/cni-cilium` outputs).
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
single-node role, custom CNI, kube-proxy setting, Pod/Service CIDRs, and
the Helm extension.
There is no separate render step — `plan` is the preview; the rendered
`k0sctl.yaml` equivalent is only known after `apply` (the `k0s_yaml`
output) since the provider builds it internally during `Create`, not
during `Plan`.

k0s is pinned to `1.36.4+k0s.0` in `cluster.tf`. The provider is pinned to
`Mirantis/k0sctl` `0.0.3` in `main.tf` — the newest version actually
published to the Terraform Registry (the GitHub repo's `v0.0.4` tag
exists but was never released there).

The apply owns k0s, its managed containerd, and the charts in
`helm_charts`. k0s installs each chart through its Helm extension
(`spec.extensions.helm`) with `--atomic --wait`, and uninstalls any chart
later removed from the list. With `helm_charts = []` the config has no
`extensions` key. This module does not install Flux or workloads.

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
| `mise run k0s:apply` | Apply the cluster and kubeconfig, then wait for the node to be Ready and Cilium to report healthy |
| `mise run k0s:dry-run` | Plan without applying |
| `mise run k0s:test` | Wait for every node to be Ready, using the rendered kubeconfig |
| `mise run k0s:unit` | Run this module's tests against a rendered plan, no live host |
