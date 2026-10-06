# orch-k0s

Abstract: OpenTofu module that renders the k0sctl configuration for one
`controller+worker` k0s node, as YAML text. It is a pure renderer: it takes
generic SSH, network and version inputs, outputs the text, and writes no
file and runs no program. The caller (`roots/kubernetes-k0s`) writes the
file and runs the pinned `k0sctl` CLI as a listed imperative edge. Generic
over the target host: this module has no OrbStack-specific knowledge.

## Inputs

`ssh_address`, `ssh_user`, `ssh_port`, `ssh_key_path`, `known_hosts_path`,
`api_address`, `pod_cidr` (required, validated; see `variables.tf`),
`cluster_name` (default `firmament`), `api_port` (default `6443`),
`service_cidr` (default `10.96.0.0/12`), `k0s_version` (default
`1.36.4+k0s.1`) and `kube_proxy_replacement` (default `true`; fixed at
cluster creation: the module records it in
`terraform_data.kube_proxy_replacement_at_creation`, and a plan with a
different value fails at the `k0sctl_yaml` output).

## Outputs

`k0sctl_yaml`: the complete k0sctl configuration as YAML text.

## Contract

`cluster.tf` is the source of truth for the cluster: single-node role,
custom CNI, kube-proxy setting, and the Pod and Service CIDRs. The host
trusts only `known_hosts_path` (`StrictHostKeyChecking: "yes"`,
`ignoreSSHConfig: true`): a wrong or missing server key refuses the
connection, and k0sctl never writes to that file. The cluster config has no
`extensions` key: k0s installs no Helm charts, since in-cluster add-ons,
the CNI included, belong to Flux. The node stays NotReady until a CNI runs;
k0sctl waits only for the API server on a `controller+worker` host.

The k0s version is the `k0s_version` default in `variables.tf`, the one
place it is set. k0sctl downloads it onto the machine, so the host runs no
k0s binary and `mise` pins only `k0sctl`. To upgrade, check the newest
stable release of `k0sproject/k0s`, change the default, and run the
module's tests; a live check is `mise run env:e2e`.

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
own; see [`environments/local`](../../environments/local/README.md) for
the full task list:

| Command | Behavior |
| --- | --- |
| `mise run k0s:apply` | Render the configuration, run `k0sctl apply` and `k0sctl kubeconfig`, check the API answers, then write the cluster-access contract; Cilium and Flux come from `env:apply` |
| `mise run k0s:plan` | Plan without applying |
| `mise run k0s:verify` | Wait for every node to be Ready, using the rendered kubeconfig |
| `mise run tofu:test` | Run `tests/unit.tftest.hcl` and `tests/creation.tftest.hcl` (and every other OpenTofu suite) against rendered text, no live host |
| `mise run k0s:test` | Run `tests/inputs.bats`, which checks that OpenTofu refuses a plan without the required inputs |
