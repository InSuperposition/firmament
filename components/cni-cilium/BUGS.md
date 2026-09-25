# Upstream bugs: Cilium

Abstract: Bug reports against [cilium/cilium](https://github.com/cilium/cilium)
found while running this module on OrbStack. Each report follows Cilium's
[bug report form](https://github.com/cilium/cilium/blob/main/.github/ISSUE_TEMPLATE/bug_report.yaml),
so its title and body can be pasted into a new issue unchanged.

## Goals

- Keep every upstream report ready to file, with evidence reproducible
  from this repo.
- Record how each bug affects this repo until upstream fixes it.

## Constraints

- Reports are filed by the repo owner. Nothing here has been filed yet.
- Re-run the duplicate search before filing; the searches below are dated.

## Socket termination disabled when only the netlink destroy path is missing

| Field | Value |
| --- | --- |
| Repository | [cilium/cilium](https://github.com/cilium/cilium/issues/new?template=bug_report.yaml) |
| Form | Bug report (`kind/community-report`, `kind/bug`, `needs/triage`) |
| Status | Not filed |
| Duplicate search | 2026-09-23, see below |
| Related OrbStack request | [vm-orb/BUGS.md](../../modules/vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy) |

**Title:** `Socket LB termination disabled on kernels with bpf_sock_destroy but without CONFIG_INET_DIAG_DESTROY (regression in 1.20)`

### Is there an existing issue for this?

- [x] I have searched the existing issues

Searched on 2026-09-23 for `CONFIG_INET_DIAG_DESTROY`,
`InetDiagDestroyEnabled`, `socket termination not supported by underlying
kernel`, `bpf_sock_destroy probe` and `orbstack`. No issue covers this.
Related but different:

- #46351 / #46391: a nil dereference inside the same `SOCK_DESTROY`
  probe. It confirms the probe first shipped in the 1.20 pre-releases.
- #37907: the BPF socket destroyer that this probe now blocks.
- #27300, #35773: the user-visible symptom, stale connected UDP sockets
  to deleted CoreDNS backends.

### Version

equal or higher than 1.20.2 and lower than v1.21.0

### What happened?

With kube-proxy replacement on, the agent logs this at start-up and never
starts the socket-termination job:

```text
level=error msg="Forcefully terminating sockets connected to deleted service backends not supported by underlying kernel" module=agent.controlplane.loadbalancer-reconciler.socket-termination error="failed while iterating sockets: not supported: operation to destroy probe socket is unsupported. This likely means that kernel CONFIG_INET_DIAG_DESTROY must be set in order for this functionality to work"
```

The kernel (OrbStack 2.2.3, Linux 7.0.14) is built without
`CONFIG_INET_DIAG_DESTROY`, but it does provide the `bpf_sock_destroy`
kfunc. Cilium's BPF socket destroyer, added in #38693, uses that kfunc
and does not need `CONFIG_INET_DIAG_DESTROY`. However,
`registerSocketTermination` gates the whole job on
`sockets.InetDiagDestroyEnabled`, a netlink-only probe added in #42867.
When that probe returns `ErrNotSupported`, the function returns before
adding the job, so the BPF destroyer is never created
([termination.go#L106-L123](https://github.com/cilium/cilium/blob/v1.20.2/pkg/loadbalancer/reconciler/termination.go#L106-L123)).

As a result, pods keep connected sockets pointed at deleted Service
backends. By default only UDP sockets are terminated
(`lb-sock-terminate-all-protos=false`), so a client with a connected UDP
socket to a replaced backend times out until it reconnects on its own.

Expected: the socket-termination job starts and uses the BPF destroyer
whenever `bpf_sock_destroy` is available, and health is marked degraded
only when neither the BPF nor the netlink destroyer can work.

### How can we reproduce the issue?

1. Use a kernel with `bpf_sock_destroy` (Linux 6.5 or later) and without
   `CONFIG_INET_DIAG_DESTROY`, for example an OrbStack 2.2.3 Linux
   machine (Ubuntu 26.04, arm64).
2. Install Cilium 1.20.2 with `kubeProxyReplacement: true`. We use k0s
   1.36.4 on a single node, with `bpf.masquerade: true`,
   `ipam.mode: kubernetes` and `bpf.datapathMode: netkit`; the result is
   the same with `veth`.
3. The agent logs the error above once at start-up, and
   `cilium connectivity test` fails only `check-log-errors` on that line.
4. Deploy a UDP echo `Deployment` (1 replica,
   `terminationGracePeriodSeconds: 1`) behind a ClusterIP `Service`, and
   a client pod that `connect()`s a UDP socket to the Service and sends
   once a second, reconnecting on error.
5. Delete the backend pod. The Deployment replaces it, but the client's
   socket stays pinned to the old backend and every send times out:

```text
13:33:14 reply from udp-echo-57975b9fd5-lxwmq
13:33:15 reply from udp-echo-57975b9fd5-lxwmq
13:33:17 timeout
13:33:19 timeout
13:33:21 timeout
...
13:33:33 timeout
```

### Cilium Version

```text
cilium-cli: v0.20.0 compiled with go1.27.0 on darwin/arm64
cilium image (running): v1.20.2 (quay.io/cilium/cilium:v1.20.2@sha256:2939231d0d3e3ebddcd80fffa168b7ddcc78fdf0dc864d1c8c126ff523c54f01)
```

### Kernel Version

```text
Linux firmament 7.0.14-orbstack-00380-ga7e0a2dc9535 #1 SMP PREEMPT Fri Aug  7 03:48:40 UTC 2026 aarch64 GNU/Linux
```

### Kubernetes Version

```text
Client Version: v1.36.4
Server Version: v1.36.4+k0s
```

### Regression

Yes. The gate was added by #42867 (merged 2026-01-21) and first shipped
in 1.20.0. v1.19.7 has the BPF destroyer (#38693, merged 2025-08-04) and
no gate: its `registerSocketTermination` starts the job unconditionally.
#46351 also reports 1.19.4 working with the same values. We did not run
1.19 on this kernel; this is from reading the v1.19.7 source.

### Sysdump

Not attached. Available on request.

### Relevant log output

```text
level=error msg="Forcefully terminating sockets connected to deleted service backends not supported by underlying kernel" module=agent.controlplane.loadbalancer-reconciler.socket-termination error="failed while iterating sockets: not supported: operation to destroy probe socket is unsupported. This likely means that kernel CONFIG_INET_DIAG_DESTROY must be set in order for this functionality to work"
```

### Anything else?

**The kernel side works.** On this kernel `bpf_sock_destroy` is present
in `/proc/kallsyms` and the BTF, and `/proc/config.gz` has
`CONFIG_INET_DIAG=y`, `CONFIG_INET_TCP_DIAG=y` and `CONFIG_INET_UDP_DIAG=y`
but no `CONFIG_INET_DIAG_DESTROY`. In v7.0, `bpf_sock_destroy` calls
`sk->sk_prot->diag_destroy`
([filter.c](https://github.com/torvalds/linux/blob/v7.0/net/core/filter.c#L12557-L12561)),
and `tcp_prot` and `udp_prot` set `.diag_destroy` with no config guard
([tcp_ipv4.c](https://github.com/torvalds/linux/blob/v7.0/net/ipv4/tcp_ipv4.c#L3465),
[udp.c](https://github.com/torvalds/linux/blob/v7.0/net/ipv4/udp.c#L3297)).
`CONFIG_INET_DIAG_DESTROY` only gates the netlink `SOCK_DESTROY` request.

**Cilium's own test agrees.** `TestPrivilegedSocketDestroyers` at v1.20.2,
cross-compiled and run as root in a fresh network namespace on this
kernel, passes every BPF case and fails every netlink case:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOFLAGS=-mod=vendor \
  go test -c -o sockets.test ./pkg/datapath/sockets
unshare --net sh -c 'ip link set lo up && PRIVILEGED_TESTS=true ./sockets.test -test.run TestPrivileged -test.v'
```

```text
--- FAIL: TestPrivilegedProbetInetDiagDestroyEnabled (0.02s)
--- FAIL: TestPrivilegedSocketDestroyers (0.04s)
    --- FAIL: TestPrivilegedSocketDestroyers/netlink (0.01s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_[::1]:8888_(UDP) (0.00s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_[::1]:8888_(TCP) (0.00s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_[::ffff:127.0.0.1]:8890_(UDP) (0.00s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_[::ffff:127.0.0.1]:8890_(TCP) (0.00s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_127.0.0.1:8888_(UDP) (0.00s)
        --- FAIL: TestPrivilegedSocketDestroyers/netlink/close_127.0.0.1:8888_(TCP) (0.00s)
    --- PASS: TestPrivilegedSocketDestroyers/bpf (0.01s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_[::1]:8888_(TCP) (0.00s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_[::ffff:127.0.0.1]:8890_(UDP) (0.00s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_[::ffff:127.0.0.1]:8890_(TCP) (0.00s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_127.0.0.1:8888_(UDP) (0.00s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_127.0.0.1:8888_(TCP) (0.00s)
        --- PASS: TestPrivilegedSocketDestroyers/bpf/close_[::1]:8888_(UDP) (0.00s)
--- PASS: TestPrivilegedIterateCallbackError (0.00s)
--- PASS: TestPrivilegedFilterAndDestroySocketsNetlinkError (0.00s)
```

Each netlink case fails with `got error response to socket destroy:
operation not supported`.

**End to end with the gate removed.** With the patch below applied to
v1.20.2 (agent built with the release `Makefile` flags, overlaid on the
official image), the agent starts the job and picks the BPF destroyer:

```text
level=warn msg="Netlink socket destroy not supported by underlying kernel; relying on the BPF socket destroyer" module=agent.controlplane.loadbalancer-reconciler.socket-termination
level=info msg="Creating BPF socket destroyer" module=agent.controlplane.loadbalancer-reconciler.socket-termination
```

Repeating step 5, the agent closes the client's socket about 135 ms
after removing the old endpoint, and the client reconnects to the new
backend within a second:

```text
level=info msg="Forcefully terminated sockets" module=agent.controlplane.loadbalancer-reconciler.socket-termination filter="{DestIp:10.244.0.78 DestPort:9000 Family:2 Protocol:17 States:65535 DestroyCB:0x290cc50}" success=1
```

```text
13:39:24 reply from udp-echo-57975b9fd5-7djfc
13:39:25 socket error EDESTADDRREQ
13:39:25 connected socket to ('udp-echo.socket-termination.svc.cluster.local', 9000)
13:39:26 reply from udp-echo-57975b9fd5-b8vkt
```

The patch used for the test:

```diff
 	if err := sockets.InetDiagDestroyEnabled(p.Log, p.Config.LBSockTerminateAllProtos, true); err != nil {
 		if errors.Is(err, probes.ErrNotSupported) {
-			// The kernel doesn't support socket termination.
-			p.Log.Error("Forcefully terminating sockets connected to deleted service backends "+
-				"not supported by underlying kernel", logfields.Error, err)
-			p.Health.Degraded("service LV socket termination not supported by kernel", err)
-			return nil
+			// The netlink destroyer is unavailable, but the BPF destroyer
+			// (bpf_sock_destroy) may still work; the job picks it first.
+			p.Log.Warn("Netlink socket destroy not supported by underlying kernel; "+
+				"relying on the BPF socket destroyer", logfields.Error, err)
+		} else {
+			p.Log.Error("Unexpected error while probing kernel socket termination support."+
+				"Will proceed with starting socket destroyer job but functionality may be degraded",
+				logfields.Error, err)
+			p.Health.Degraded("Unexpected error while probing kernel socket termination support",
+				err)
 		}
-		p.Log.Error("Unexpected error while probing kernel socket termination support."+
-			"Will proceed with starting socket destroyer job but functionality may be degraded",
-			logfields.Error, err)
-		p.Health.Degraded("Unexpected error while probing kernel socket termination support",
-			err)
 	}
```

This patch only proves the diagnosis. On a kernel with neither destroyer
it would start the job without marking health degraded. A proper fix
should decide from both capabilities: check `bpf_sock_destroy` support
(as `NewSocketDestroyer` already does) before the netlink probe, and
report degraded only when neither works. Happy to open a PR along those
lines.

### Cilium Users Document

- [ ] Are you a user of Cilium? Please add yourself to the [Users doc](https://github.com/cilium/cilium/blob/main/USERS.md)

### Code of Conduct

- [x] I agree to follow this project's Code of Conduct

### Notes for this repo (not part of the issue)

- `mise run cilium:conformance` passes `--log-check-only-test-time`, so
  the start-up error does not fail the suite, while agent errors logged
  during the tests still do. Remove the flag once either this fix or the
  [OrbStack kernel request](../../modules/vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy)
  lands.
- Until either fix lands, `components/cni-cilium` sets
  `socketLB.hostNamespaceOnly: true`, so pods use per-packet Service
  translation and follow a replaced backend (verified live with the
  scenario in step 4). Revisit that setting once socket termination
  works.
- Evidence gathered 2026-09-23 with Cilium 1.20.2, OrbStack
  `2.2.3 (2020300)`, macOS 26.6.2 (arm64), Ubuntu 26.04.1, k0s
  `1.36.4+k0s.0`, single node.

## Flow validation never matches reverse-NATed Service replies

| Field | Value |
| --- | --- |
| Repository | [cilium/cilium](https://github.com/cilium/cilium/issues/new?template=bug_report.yaml) (cilium-cli lives in `cilium-cli/`) |
| Form | Bug report (`kind/community-report`, `kind/bug`, `needs/triage`) |
| Status | Not filed |
| Duplicate search | 2026-09-24, widened 2026-09-25 (issues and PRs in cilium/cilium and cilium/cilium-cli), see below |
| Related | cilium/cilium-cli#3255, #419, #2103, #183, #52; cilium/cilium#32130, #47936; cilium/hubble#349 |

**Title:** `cilium-cli: connectivity test flow validation matches only IP.Source, so Service replies reverse-NATed in bpf_lxc never match (ClusterIP is in IP.SourceXlated)`

### Is there an existing issue for this?

- [x] I have searched the existing issues

Searched on 2026-09-24 in cilium/cilium, cilium/cilium-cli and
cilium/hubble for `"flow validation failed"`, `flow-validation strict`,
`SourceXlated`, `xlated`, `missing SYN-ACK`, `pod-to-service flow
validation`, `service ip`, `ClusterIP`, `monitor aggregation` and
`orbstack`. No open issue covers this. Related:

- cilium/cilium-cli#3255 (2026-06-18, closed as stale 2026-09-02): the
  same test fails with socket LB on (Talos, Cilium 1.19.5). There the
  SYN to the ClusterIP never appears, because the socket hook translates
  before any packet exists. This report is the tc-level LB case; both
  come from the CLI expecting the ClusterIP in the plain IP fields.
- cilium/cilium#32130 (merged 2024-05-08): added `IP.source_xlated` to
  Hubble flows. The CLI's IP matching has not changed since 2022 and does
  not read it.
- cilium/cilium-cli#419 (closed as stale): a missing SYN-ACK on
  `pod-to-local-nodeport`, likely the same field mismatch.
- cilium/cilium-cli#52 (closed as stale): asks the test to fail when
  monitor aggregation is not `none`; see the second cause below.
- cilium/hubble#349 (open since 2020): `hubble observe --service` shows
  no traffic for a Service, a user-facing symptom of the same
  representation.
- cilium/cilium#16392, #16291 (2021, closed): CI flakes on the same test
  with older code.
- cilium/cilium-cli#2103 (2023, closed as stale 2024-10-13, not merged):
  "Fix flow validation for nodeport service tests" reworked
  `AltDstPort` handling for NodePort scenarios. Its target was a wrong
  IP family, but it shows the scenarios' alternate-address handling was
  known to be incomplete.
- cilium/cilium-cli#183 (merged 2021): marks the SYN-ACK requirement
  `SkipOnAggregation`, so with aggregation on only the SYN half is
  checked. That is why the chart default fails on the SYN instead.
- cilium/cilium#47936 (2026-08, closed without merging): would make
  `TO_OVERLAY` traces of SNATed NodePort traffic report the client in
  `source` and the SNAT address in `source_xlated`, the same convention
  that defeats the CLI's matching here.

### Version

equal or higher than 1.20.2 and lower than v1.21.0

### What happened?

`cilium connectivity test` with flow validation (Hubble reachable, mode
`warning` or `strict`) fails `no-policies`, `allow-all-except-world`
and `pod-to-itself-via-service` on their pod-to-service actions,
although every connection completes. The SYN-ACK requirement is never
met:

```text
ℹ️  SYN-ACK and(ip(src=10.105.75.67,dst=10.244.0.253),tcp(srcPort=8080),tcpflags(syn,ack)) not found
```

The reply is in Hubble, with the ClusterIP in the translated field:

1. `ipv4_policy()` in `bpf/bpf_lxc.c` saves `orig_sip`, reverse-NATs
   the reply to the ClusterIP with `lb4_rev_nat()`, then emits
   `TRACE_TO_LXC` with `orig_sip`, the backend address
   ([bpf_lxc.c#L2181](https://github.com/cilium/cilium/blob/v1.20.2/bpf/bpf_lxc.c#L2181),
   [#L2224](https://github.com/cilium/cilium/blob/v1.20.2/bpf/bpf_lxc.c#L2224),
   [#L2315](https://github.com/cilium/cilium/blob/v1.20.2/bpf/bpf_lxc.c#L2315)).
2. The Hubble parser puts that `OrigIP` in `IP.Source` and moves the
   header's source, the ClusterIP, to `IP.SourceXlated`
   ([parser.go#L252-L263](https://github.com/cilium/cilium/blob/v1.20.2/pkg/hubble/parser/threefour/parser.go#L252-L263)).
3. The CLI's IP filter compares only `ip.Source`
   ([filters.go#L387](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/filters/filters.go#L387)),
   and the Service scenarios pass no `AltDstIP` for the backend
   ([service.go#L62](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/tests/service.go#L62)).

Hubble's own output for one such reply, the SYN-ACK arriving at the
client (`hubble observe -o json`, veth datapath, Service
`10.105.81.168`, backend `10.244.0.159`, client `10.244.0.18`):

```json
{"trace_observation_point":"TO_ENDPOINT","IP":{"source":"10.244.0.159","source_xlated":"10.105.81.168","destination":"10.244.0.18"}}
```

So no reply flow can match `src=<ClusterIP>`. A second cause hides the
request side too: with the chart's default `bpf.monitorAggregation:
medium`, `emit_trace_notify()` drops every `TRACE_FROM_*` event
([trace.h#L179-L194](https://github.com/cilium/cilium/blob/v1.20.2/bpf/lib/trace.h#L179-L194)),
so the pre-DNAT SYN (`from-endpoint`) is not reported. With
`cilium config set monitor-aggregation none` the SYN matches and only
the SYN-ACK fails. The CLI prints `Monitor aggregation detected, will
skip some flow validation steps`, but still requires both.

Expected: the IP filter also accepts `IP.SourceXlated` and
`IP.DestinationXlated` for Service destinations (or the Service
scenarios pass the backend as `AltDstIP`).

### How can we reproduce the issue?

1. Install Cilium 1.20.2 with `kubeProxyReplacement: true` and
   `socketLB.hostNamespaceOnly: true`, so pods use tc-level Service
   translation. We use k0s 1.36.4 on one node, `bpf.datapathMode:
   netkit` (the same on `veth`), `bpf.masquerade: true`, Hubble Relay
   enabled.
2. `cilium hubble port-forward &`
3. `cilium connectivity test --hubble-server localhost:4245 --test no-policies,allow-all-except-world,pod-to-itself-via-service`

### Cilium Version

```text
cilium-cli: v0.20.1 compiled with go1.27.1 on darwin/arm64
cilium image (running): v1.20.2
```

First found with cilium-cli v0.20.0, which builds its connectivity tests
from cilium/cilium commit `ef5d47de14d0`; the links point at that commit.
v0.20.1 (2026-09-24, commit `7c4e5469a2fc`) has the same code and fails
the same way.

### Kernel Version

```text
Linux firmament 7.0.14-orbstack-00380-ga7e0a2dc9535 #1 SMP PREEMPT Fri Aug  7 03:48:40 UTC 2026 aarch64 GNU/Linux
```

### Kubernetes Version

```text
Client Version: v1.36.4
Server Version: v1.36.4+k0s
```

### Regression

Unknown. Cilium's CI runs the connectivity test with
`--flow-validation=disabled` unless a job opts in
([cli-test-config/action.yaml](https://github.com/cilium/cilium/blob/main/.github/actions/cli-test-config/action.yaml)),
so these expectations are not exercised.

### Relevant log output

```text
❌ 4/79 tests failed (7/311 actions), 58 tests skipped, 0 scenarios skipped:
  🟥 no-policies/pod-to-service:curl-ipv4-0: ... Flow validation failed
  🟥 allow-all-except-world/pod-to-service:curl-ipv4-0: ... Flow validation failed
  🟥 pod-to-itself-via-service/pod-to-itself-via-service:curl-ipv4-0: ... Flow validation failed
  🟥 to-fqdns/pod-to-world:http-to-one.one.one.one.-ipv4-0: ... Flow validation failed
```

The fourth failure is the next report.

### Anything else?

Hubble shows each failing connection complete: `FORWARDED` SYN,
SYN-ACK, data and FIN between the client and the backend pod.

The same pattern is in every scenario that validates flows against a
translated frontend without passing the backend as `AltDstIP`, as of
cilium-cli 0.20.1 (commit `7c4e5469a2fc`):

- `pod-to-service` ([service.go#L62](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L62)), the one reported here
- `pod-to-ingress-service` ([service.go#L119](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L119), [#L129](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L129))
- `pod-to-local-nodeport` ([service.go#L271](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L271)), matching the missing SYN-ACK in cilium/cilium-cli#419
- `outside-to-ingress-service` ([service.go#L342](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L342))
- L7 Service scenarios ([service.go#L401](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/service.go#L401))
- `lrp` ([lrp.go#L166](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/lrp.go#L166))
- `pod-to-k8s-on-localhost` ([k8s.go#L40](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/k8s.go#L40))

`pod-to-hostport` already passes the backend as `AltDstIP`
([host.go#L162](https://github.com/cilium/cilium/blob/7c4e5469a2fc/cilium-cli/connectivity/tests/host.go#L162)) and passes flow validation
here, so the same approach, or matching `IP.source_xlated`, would fix
the others. Only `pod-to-service` and `pod-to-itself-via-service` ran on
our single-node cluster. The others are listed from the source and are
unverified.

### Sysdump

Not attached. Available on request.

### Cilium Users Document

- [ ] Are you a user of Cilium? Please add yourself to the [Users doc](https://github.com/cilium/cilium/blob/main/USERS.md)

### Code of Conduct

- [x] I agree to follow this project's Code of Conduct

### Notes for this repo (not part of the issue)

- Not caused by OrbStack: #3255 fails the same test on Talos, and the
  mismatch is in the parser and CLI code above. OrbStack is linked only
  through `socketLB.hostNamespaceOnly: true`, which this repo sets
  because of the
  [OrbStack kernel request](../../modules/vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy).
  With socket LB on in pods the test fails the other way, as in #3255.
- Compared on 2026-09-25: the same four tests (7 of 311 actions) fail on
  `bpf.datapathMode: veth` with every other setting unchanged, and with
  `monitor-aggregation none` the same SYN-ACK requirement still fails on
  veth. The cause does not depend on the datapath.
- Evidence gathered 2026-09-24 with the versions above, OrbStack
  `2.2.3 (2020300)`, macOS 26.6.2 (arm64), Ubuntu 26.04.1.

## `to-fqdns` expects an HTTP flow its policy no longer produces

| Field | Value |
| --- | --- |
| Repository | [cilium/cilium](https://github.com/cilium/cilium/issues/new?template=bug_report.yaml) (cilium-cli lives in `cilium-cli/`) |
| Form | Bug report (`kind/community-report`, `kind/bug`, `needs/triage`) |
| Status | Not filed |
| Duplicate search | 2026-09-25, same searches as above plus `to-fqdns flow validation HTTP`, `to-fqdns HTTP flow` |
| Introduced by | cilium/cilium#38750 (commit `62e3be9d8a`, merged 2025-04-23) |

**Title:** `cilium-cli: to-fqdns flow validation expects an HTTP GET flow, but client-egress-to-fqdns.yaml has had no HTTP rule since #38750`

### Is there an existing issue for this?

- [x] I have searched the existing issues

No issue found. Related but different:

- cilium/cilium#16096 (2021, closed): a flake on the older
  `pod-to-world-toFQDNs` test.
- cilium/cilium#48794 (open, 2026-09-17): `to-fqdns` and other DNS-rule
  tests fail on Gardener because its DNS listens on port 8053. That is
  a traffic failure, not a flow-validation mismatch.

Every other scenario that expects an HTTP flow passed flow validation
in two full runs (netkit and veth), so `to-fqdns` is the only one whose
expectation and policy disagree.

### Version

equal or higher than 1.20.2 and lower than v1.21.0

### What happened?

With flow validation on, `to-fqdns/pod-to-world:http-to-one.one.one.one.`
fails although the request succeeds:

```text
ℹ️  HTTP and(ip(src=10.244.0.253),tcp(dstPort=80),http(method=GET,url=http://one.one.one.one/)) not found
```

Commit `62e3be9d8a` ("Add `external-target-ipv6-capable` flag", in
#38750) split the FQDN tests. It removed the `rules: http: GET /` block
from `client-egress-to-fqdns.yaml` and moved L7 checking to the new
`to-fqdns-with-proxy` test, but left the HTTP expectation in `to-fqdns`
([to_fqdns.go#L45-L54](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/builder/to_fqdns.go#L45-L54)).
`GetEgressRequirements` then requires an HTTP flow whenever
`expEgress.HTTP` is set
([action.go#L743-L757](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/check/action.go#L743-L757)).
The policy is L3/L4 only, so traffic is never redirected to Envoy:
Hubble shows `policy-verdict:L3-L4` then `to-network`, which is correct.

Expected: `to-fqdns` expects `check.ResultDNSOK` without an HTTP flow,
as its policy dictates.

### How can we reproduce the issue?

`cilium connectivity test --hubble-server localhost:4245 --test to-fqdns`
on any cluster with the L7 proxy enabled and Hubble Relay reachable.

### Cilium Version

```text
cilium-cli: v0.20.1 compiled with go1.27.1 on darwin/arm64
cilium image (running): v1.20.2
```

First found with cilium-cli v0.20.0, which builds its connectivity tests
from cilium/cilium commit `ef5d47de14d0`; the links point at that commit.
v0.20.1 (2026-09-24, commit `7c4e5469a2fc`) has the same code and fails
the same way.

### Kernel Version

```text
Linux firmament 7.0.14-orbstack-00380-ga7e0a2dc9535 #1 SMP PREEMPT Fri Aug  7 03:48:40 UTC 2026 aarch64 GNU/Linux
```

### Kubernetes Version

```text
Client Version: v1.36.4
Server Version: v1.36.4+k0s
```

### Regression

Yes, since #38750 (merged 2025-04-23). Before it, the policy had the
HTTP rule that the expectation assumes.

### Sysdump

Not attached. Available on request.

### Cilium Users Document

- [ ] Are you a user of Cilium? Please add yourself to the [Users doc](https://github.com/cilium/cilium/blob/main/USERS.md)

### Code of Conduct

- [x] I agree to follow this project's Code of Conduct

## `--flow-validation warning` fails the run on flow mismatches

| Field | Value |
| --- | --- |
| Repository | [cilium/cilium](https://github.com/cilium/cilium/issues/new?template=bug_report.yaml) (cilium-cli lives in `cilium-cli/`) |
| Form | Bug report (`kind/community-report`, `kind/bug`, `needs/triage`) |
| Status | Not filed |
| Duplicate search | 2026-09-25, `flow-validation warning`, `flow validation mode`, `flow-validation disabled` (issues and PRs) |
| Related | cilium/cilium-cli#340 (closed as stale 2024-10-13), #293, #307 |

**Title:** `cilium-cli: --flow-validation=warning fails tests on flow mismatches exactly like strict; the modes differ only when Hubble is unreachable`

### Is there an existing issue for this?

- [x] I have searched the existing issues

cilium/cilium-cli#293 and #307 (merged 2022) added `disabled`, which
made the mode a tri-state. cilium/cilium-cli#340 asked to clean up the tri-state
`--flow-validation` because "different code paths check
`params.FlowValidation` for different values"; it was closed as stale
without a change.

### What happened?

`cilium connectivity test --help` lists `--flow-validation string
Enable Hubble flow validation { disabled | warning | strict } (default
"warning")`. The name suggests `warning` reports mismatches without
failing. It does not: `ValidateFlows` returns early only for
`disabled`, and otherwise calls `a.Failf` on any mismatch
([action.go#L1065-L1094](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/check/action.go#L1065-L1094)).
The only difference is when Hubble Relay is unreachable: `strict` fails,
while `warning` logs `Unable to contact Hubble Relay, disabling Hubble
telescope and flow validation` and passes
([context.go#L655-L671](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/check/context.go#L655-L671)).

So with the default mode, a run is green when Hubble cannot be reached
and red on the same cluster when it can. Our runs passed 79/79 for
weeks only because nothing forwarded Relay to `localhost:4245`.

Expected: either `warning` downgrades flow mismatches to warnings, or
the help text says that it only tolerates an unreachable Hubble.

### Cilium Version

```text
cilium-cli: v0.20.1 compiled with go1.27.1 on darwin/arm64
cilium image (running): v1.20.2
```

First found with cilium-cli v0.20.0, which builds its connectivity tests
from cilium/cilium commit `ef5d47de14d0`; the links point at that commit.
v0.20.1 (2026-09-24, commit `7c4e5469a2fc`) has the same code and fails
the same way.

### Kernel Version

```text
Linux firmament 7.0.14-orbstack-00380-ga7e0a2dc9535 #1 SMP PREEMPT Fri Aug  7 03:48:40 UTC 2026 aarch64 GNU/Linux
```

### Kubernetes Version

```text
Client Version: v1.36.4
Server Version: v1.36.4+k0s
```

### Sysdump

Not attached. Available on request.

### Cilium Users Document

- [ ] Are you a user of Cilium? Please add yourself to the [Users doc](https://github.com/cilium/cilium/blob/main/USERS.md)

### Code of Conduct

- [x] I agree to follow this project's Code of Conduct

### Notes for this repo (not part of the three issues above)

- `mise run cilium:conformance` forwards Hubble Relay, fails when Relay
  is unreachable, and runs `--flow-validation disabled`. Hubble still
  records each action's flows and prints them for any action that
  fails; only the flow assertions are off. Cilium's own CI runs the
  same way.
- Switch to `--flow-validation strict` once a cilium-cli release fixes
  the Service reply matching and the `to-fqdns` expectation above.
  Check each release: run the four tests (`no-policies`,
  `allow-all-except-world`, `pod-to-itself-via-service`, `to-fqdns`)
  with `--flow-validation strict` against a live cluster.
- `strict` fails the same four tests (7 actions) with cilium-cli 0.20.0
  and 0.20.1, on both `netkit` and `veth`. `monitor-aggregation none`
  fixes only the SYN half, and would raise event volume on every node.
