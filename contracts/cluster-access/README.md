# cluster-access

Abstract: Where the cluster's kubeconfig is, and the runtime values every
package reads. `roots/kubernetes-k0s` writes `cluster-access.yaml` into the
environment's state directory; `roots/bootstrap-flux` and the mise tasks
read it. The schema (`schema.cue`) is closed. `mise run contracts:lint`
checks the sample beside it, and `roots/bootstrap-flux` checks the file it
reads against the same fields at plan time, naming the field that fails.

| Field | Type | Rule |
| --- | --- | --- |
| `kubeconfig_path` | string | not empty |
| `runtime_info.api_address` | string | |
| `runtime_info.api_port` | string | |
| `runtime_info.kube_proxy_replacement` | string | |
| `runtime_info.cilium_datapath_mode` | string | |
| `runtime_info.cilium_operator_replicas` | string | |
| `runtime_info.environment` | string | |
| `runtime_info.cluster` | string | |
| `runtime_info.git_branch` | string | |

Every `runtime_info` value is a string: Flux substitution is plain text
replacement, so a number would not substitute.

See also [machine-hosts](../machine-hosts/README.md) and
[environment](../environment/README.md); change a field name in all of
them together.
