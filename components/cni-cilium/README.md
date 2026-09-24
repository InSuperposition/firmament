# cni-cilium

Abstract: The Flux component that runs Cilium, with Hubble Relay and
Hubble UI, as the cluster network. The OpenTofu bootstrap installs the
chart once, before any pod network exists; Flux then adopts the release
and upgrades it from these manifests.

## Goals

- One place that pins the Cilium chart and its values, read by both the
  bootstrap and Flux.
- Upgrades flow through Git, and a failed upgrade rolls back.

## Constraints

- The chart `quay.io/cilium/charts/cilium` is pinned by digest (1.20.2)
  in `ocirepository.yaml`, and every enabled image is pulled by digest.
- The release is `cilium`, in `kube-system`, stored there by Helm. The
  bootstrap installs it under the same identity, so Flux adopts it
  instead of installing a second copy.
- IPAM mode, kube-proxy replacement and the pod datapath cannot change on
  a live cluster. Changing any of them means rebuilding the cluster.
- `upgradeCompatibility` stays at `1.20`, the version first installed,
  until an explicitly tested migration changes it. Upgrade minors one at
  a time, after the latest patch of the current minor.

## Files

| File | Role |
| --- | --- |
| `ocirepository.yaml` | Chart source, by digest |
| `helmrelease.yaml` | Release identity, `valuesFrom` the `cilium-values` ConfigMap, upgrade remediation (3 retries, then rollback; never forced), prune disabled |
| `values.yaml` | Chart values; `kustomization.yaml` turns it into the `cilium-values` ConfigMap, labeled so a change triggers an upgrade |

## Runtime values

`values.yaml` has no conditionals: Flux substitution is plain text
replacement. The environment computes each value in OpenTofu and passes it
through the `flux-runtime-info` ConfigMap. The bootstrap substitutes them
once, and Flux on every reconcile.

| Variable | Sets | Local value |
| --- | --- | --- |
| `api_address` | `k8sServiceHost` (always a string) | the machine's OrbStack DNS name |
| `api_port` | `k8sServicePort` | `6443` |
| `kube_proxy_replacement` | `kubeProxyReplacement`, `bpf.masquerade` | `true` |
| `cilium_datapath_mode` | `bpf.datapathMode` | `netkit` (`veth` beside kube-proxy) |
| `cilium_operator_replicas` | `operator.replicas` | `1`; the chart spreads operator replicas across nodes, so one node needs 1 |

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

The HelmRelease sets `upgrade.force: false`. A forced upgrade recreates
objects instead of patching them, and the hubble-generate-certs Job
cannot be recreated in place.

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
[vm-orb/BUGS.md](../../modules/vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy).

## Commands

Run from the repo root:

| Command | Behavior |
| --- | --- |
| `mise run cilium:test` | Run `tests/values.bats`: renders `values.yaml` with `flux envsubst --strict` and checks the release, source and values, no cluster |
| `mise run cilium:verify` | Wait for the Cilium agent, operator, Hubble Relay and Hubble UI |
| `mise run cilium:conformance` | Run Cilium's connectivity test suite against the live cluster, checking only logs written during the tests, then remove its test workloads; a failed run keeps them for debugging (slow, manual only) |

To open the Hubble UI or observe flows against the live cluster:

```sh
cilium hubble ui
cilium hubble port-forward &
hubble observe
```
