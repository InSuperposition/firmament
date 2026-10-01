# kubernetes-k0s

Abstract: The Kubernetes root. Reads the `machine-hosts` contract the
machine root wrote, installs k0s on that host with `modules/orch-k0s`,
writes the kubeconfig, and writes the `cluster-access` contract the
bootstrap root and the tasks read. It knows nothing about OrbStack: any
machine root that writes the same contract can feed it.

## Contracts

In: `machine-hosts.yaml` (see `roots/machine-orb`). Planning without it
fails and names the file.

Out: `cluster-access.yaml`, next to the kubeconfig. Destroying this root
deletes both, so a missing file means no cluster.

```yaml
kubeconfig_path: <state directory>/admin.kubeconfig
runtime_info:
  api_address: firmament.orb.local
  api_port: "6443"
  kube_proxy_replacement: "true"
  cilium_datapath_mode: netkit
  cilium_operator_replicas: "1"
  environment: local
  git_branch: main
```

`runtime_info` carries the values the packages substitute. Flux
substitution is plain text replacement and cannot evaluate conditionals,
so every derived value is computed here. `env:verify` passes the same
values to the chainsaw suites as `$values`, so a package suite checks the
cluster against what the environment asked for.

k0s installs no Helm charts, so the node stays NotReady until Cilium runs.
The machine's DNS name and port 6443 reach both k0s and Cilium's values,
so k0s serves the API where Cilium's agent connects.

## Cilium replaces kube-proxy

`kube_proxy_replacement = true` for both k0s (`kubeProxy.disabled`) and
Cilium (`kubeProxyReplacement`), which also selects Cilium's netkit pod
datapath with BPF masquerading. It is not a variable, because no
environment runs kube-proxy. `modules/orch-k0s` and the Cilium values
still accept `false`, and `modules/orch-k0s` refuses to change the value
on an existing cluster, since Cilium documents no live migration between
the two modes for a single node.

`drain_before_upgrade = false`: on one node a drain before a k0s upgrade
would evict every pod with nowhere to go. `reset_on_destroy = false`:
k0s goes with the machine, so a reset over SSH would be redundant.

## Inputs

| Variable | Set by |
| --- | --- |
| `state_directory` | the mise tasks (`TF_VAR_state_directory`) |
| `environment` | the mise tasks (`TF_VAR_environment`), the task's environment argument |
| `git_branch` | the mise tasks: the checked-out branch, or `FIRMAMENT_GIT_BRANCH` |

State: `$FIRMAMENT_STATE_HOME/environment/<env>/kubernetes-k0s.tfstate`.

## Tests

`tests/integration.bats` plans this root against the
`tests/fixtures/machine-hosts.yaml` contract. `tests/inputs.tftest.hcl`
checks the branch and environment validations.
