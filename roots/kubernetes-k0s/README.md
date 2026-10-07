# kubernetes-k0s

Abstract: The Kubernetes root. Reads the `machine-hosts` contract the
machine root wrote, renders the k0sctl configuration for that host with
`modules/orch-k0s`, writes it and its `known_hosts` trust file, and, in the
publish pass, writes the `cluster-access` contract the bootstrap root and
the tasks read. It runs no program: a mise task runs the pinned `k0sctl`
between the passes (see below). It knows nothing about OrbStack: any
machine root that writes the same contract can feed it.

## Contracts

In: `machine-hosts.yaml` (see `roots/machine-orb`). Planning without it
fails and names the file.

Out: `known_hosts` and `k0sctl.yaml` (both mode 0600) in the state
directory, and `cluster-access.yaml`. The kubeconfig, `admin.kubeconfig`,
is written by the k0sctl edge, not by OpenTofu. A missing
`cluster-access.yaml` means no cluster: it exists only after the edge has the
API answering.

```yaml
kubeconfig_path: <state directory>/admin.kubeconfig
runtime_info:
  api_address: 192.168.139.10
  api_port: "6443"
  kube_proxy_replacement: "true"
  cilium_datapath_mode: netkit
  cilium_operator_replicas: "1"
  environment: local
  cluster: singularity
  git_branch: main
```

`runtime_info` carries the values the packages substitute. Flux
substitution is plain text replacement and cannot evaluate conditionals,
so every derived value is computed here. `env:verify` passes the same
values to the chainsaw suites as `$values`, so a package suite checks the
cluster against what the environment asked for.

k0s installs no Helm charts, so the node stays NotReady until Cilium runs.
The machine's recorded IP (an `.orb.local` name goes stale after a rebuild)
and port 6443 reach both k0s and Cilium's values, so k0s serves the API
where Cilium's agent connects.

## Passes and the k0sctl edge

`k0s:apply` and `env:apply` run one shared sequence: `refuse_k0s_charts`; a
render pass (`publish_cluster_access=false`, which removes
`cluster-access.yaml`); `k0sctl apply --no-drain` on every run, bounded by
`FIRMAMENT_K0SCTL_SECONDS`; `k0sctl kubeconfig` written to a temp file and
moved to `admin.kubeconfig` (mode 0600); the API must answer at the
recorded IP; then the publish pass writes `cluster-access.yaml`. A failed
run leaves no `cluster-access.yaml`, and a rerun is safe: `k0sctl apply` is
idempotent. `known_hosts` and `StrictHostKeyChecking: "yes"` make a wrong
or missing server key refuse the connection.

## Mesh allocations are append-only

For every cluster in `environments/<env>/environment.yaml`, a
`terraform_data.allocation` record keeps the first `mesh_id` and `pod_cidr`
this root saw. A changed value fails the plan naming the cluster; a cluster
removed from the data (instead of marked `retired: true`) fails on
`prevent_destroy`. Retired clusters keep counting: `mesh_id` stays unique,
`pod_cidr` ranges must not overlap and must stay outside the service CIDR
`10.96.0.0/12`, and a retired cluster cannot be the one an environment
runs. The records live in state, so an environment with no state is not
checked; `env:destroy` and `orb:destroy` run `tofu state rm` on them before
destroying the root.

## Cilium replaces kube-proxy

`kube_proxy_replacement = true` for both k0s (`kubeProxy.disabled`) and
Cilium (`kubeProxyReplacement`), which also selects Cilium's netkit pod
datapath with BPF masquerading. It is not a variable, because no
environment runs kube-proxy. `modules/orch-k0s` and the Cilium values
still accept `false`, and `modules/orch-k0s` refuses to change the value
on an existing cluster, since Cilium documents no live migration between
the two modes for a single node.

The edge passes `--no-drain`: on one node a drain before a k0s upgrade
would evict every pod with nowhere to go. Destroy resets nothing over SSH:
k0s goes with the machine.

## Inputs

| Variable | Set by |
| --- | --- |
| `state_directory` | the mise tasks (`TF_VAR_state_directory`) |
| `environment` | the mise tasks (`TF_VAR_environment`), from `MISE_ENV` |
| `environments/<environment>/environment.yaml` | read from the repository: `cluster` names the cluster definition, which must have `clusters/<cluster>/flux/kustomization.yaml` |
| `environments_directory` | tests only: where to read `<environment>/environment.yaml` instead of the repository's `environments/` |
| `git_branch` | the mise tasks: the checked-out branch, or `FIRMAMENT_GIT_BRANCH` |
| `publish_cluster_access` | the shared apply sequence: `true` only in the publish pass; default `false` |

State: `$FIRMAMENT_STATE_HOME/environments/<env>/kubernetes-k0s.tfstate`.

## Tests

`tests/integration.bats` plans this root against the
`tests/fixtures/machine-hosts.yaml` contract: the rendered `k0sctl.yaml`
and `known_hosts`, the machine IP and allocation pod CIDR, the publish
pass, and every allocation rule against the fixture environments (applied
into a throwaway state file, so append-only checks see a recorded value).
`tests/inputs.tftest.hcl` checks the branch and environment validations,
and rejects a planted value in the machine-hosts and environment contracts
(`ssh.port`, `ssh.host_keys` absent, empty or malformed, `cluster`,
`artifact_source`, an undeclared field), each naming the field.
