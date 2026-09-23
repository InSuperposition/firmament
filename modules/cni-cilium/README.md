# cni-cilium

Abstract: OpenTofu module that declares the Cilium Helm chart, with
Hubble Relay and Hubble UI enabled, for a cluster's Helm chart
installer. It renders data only: it has no providers, no resources, and
no state, so it can be planned and tested without a cluster.

## Goals

- One place that pins the Cilium chart version and its values.
- Output shaped for `modules/orch-k0s`'s `helm_charts` input, so k0s
  installs Cilium during cluster bring-up.

## Constraints

- The chart is pinned to `cilium/cilium` `1.20.2` from
  <https://helm.cilium.io>, installed into `kube-system`.
- IPAM mode, kube-proxy replacement and the pod datapath cannot change on
  a live cluster. Changing any of them means rebuilding the cluster.

## Inputs

| Input | Default | Behavior |
| --- | --- | --- |
| `api_host` | required | Kubernetes API host the agent connects to directly (`k8sServiceHost`) |
| `api_port` | `6443` | Kubernetes API port (`k8sServicePort`); must match the cluster's API port |
| `kube_proxy_replacement` | required | Renders `kubeProxyReplacement` and selects the datapath; must match the cluster's kube-proxy setting |
| `operator_replicas` | `2` | Cilium operator replicas; at least 1. The chart requires operator replicas on different nodes, so a single-node cluster needs 1 |

## Output

`helm_chart`: `repository` (`name`, `url`) and `chart` (`name`,
`chartname`, `version`, `namespace`, `forceUpgrade`, `values`). `values`
is the YAML rendered from [`values.yaml.tftpl`](values.yaml.tftpl).

## Values

| Value | Setting | Reason |
| --- | --- | --- |
| `bpf.datapathMode` | `netkit` with kube-proxy replacement, else `veth` | netkit is Cilium's faster pod device, and the agent refuses to start with it unless kube-proxy replacement is on. netkit needs a kernel with `CONFIG_NETKIT` (Linux 6.7 or later), which Ubuntu 26.04 and OrbStack both provide |
| `bpf.masquerade` | `true` with kube-proxy replacement, else `false` | netkit requires BPF masquerading, which also enables BPF host routing |
| `socketLB.hostNamespaceOnly` | `true` | Pod traffic to Services is translated per packet instead of when the socket connects, so a pod's connected socket follows a replaced backend. See [Socket termination](#socket-termination) |
| `ipam.mode` | `kubernetes` | Pod IPs come from each node's podCIDR. The chart default pool `10.0.0.0/8` overlaps common LANs and the Service CIDR |
| `hubble.relay.enabled`, `hubble.ui.enabled` | `true` | Cluster-wide flow visibility through `hubble` and the Hubble UI |
| `rollOutCiliumPods`, `envoy.rollOutPods`, `operator.rollOutPods`, `hubble.relay.rollOutPods`, `hubble.ui.rollOutPods` | `true` | A values change restarts the affected pods on apply. The chart default (`false`) updates the ConfigMap and leaves running pods on the old configuration |
| `hubble.tls.auto.method` | `cronJob` | A CronJob renews the Hubble mTLS certificates (valid 365 days) every four months. The chart default (`helm`) renews them only when the chart is upgraded |

The chart declaration also sets `forceUpgrade: false`. k0s upgrades
charts with `helm upgrade --force` by default, which recreates objects
instead of patching them. The certificate Job cannot be recreated in
place, so a forced upgrade fails and k0s retries it indefinitely.

## Socket termination

Cilium logs this error once when the agent starts, and marks the
socket-termination module degraded:

```text
level=error msg="Forcefully terminating sockets connected to deleted service backends not supported by underlying kernel"
```

With kube-proxy replacement, Cilium picks a Service backend when a pod
connects its socket. When that backend is deleted, Cilium should close
the pod's sockets to it, so the application reconnects to a live
backend. On OrbStack this does not happen. OrbStack's kernel lacks
`CONFIG_INET_DIAG_DESTROY`, so Cilium's netlink start-up check fails and
Cilium 1.20 disables the whole feature, even though its BPF socket
destroyer works on this kernel. By default only UDP sockets are affected. For
example, a client that holds a connected UDP socket to a CoreDNS pod
would keep sending to it after that pod is replaced.

`socketLB.hostNamespaceOnly: true` avoids this for pods: Cilium
translates their Service traffic per packet instead of at connect time,
so there is no stale socket to close. A connected UDP client was checked
on the live cluster: after its backend pod was replaced, the next reply
came from the new pod on the same socket, with no timeout or error.
Processes in the host network namespace still use socket-level load
balancing and keep the gap.

`cilium:conformance` passes `--log-check-only-test-time`, so this
start-up error does not fail the suite; agent errors logged while the
tests run still do. The Cilium bug report is in [BUGS.md](BUGS.md), and
the OrbStack kernel request is in
[vm-orb/BUGS.md](../vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy).

## Commands

Run from the repo root:

| Command | Behavior |
| --- | --- |
| `mise run tofu:test` | Run `tests/unit.tftest.hcl` (and every other OpenTofu suite) against rendered plans, no cluster |
| `mise run cilium:test` | Run `tests/inputs.bats`, which checks that OpenTofu refuses a plan without the required inputs |
| `mise run cilium:verify` | Wait for the Cilium agent, operator, Hubble Relay and Hubble UI |
| `mise run cilium:conformance` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests (slow, manual only) |

To open the Hubble UI or observe flows against the live cluster:

```sh
cilium hubble ui
cilium hubble port-forward &
hubble observe
```
