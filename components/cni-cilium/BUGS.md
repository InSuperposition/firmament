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

## Connectivity test flow validation cannot match service replies

| Field | Value |
| --- | --- |
| Repository | [cilium/cilium](https://github.com/cilium/cilium/issues/new?template=bug_report.yaml) (cilium-cli lives in `cilium-cli/`) |
| Form | Bug report (`kind/community-report`, `kind/bug`, `needs/triage`) |
| Status | Not filed |
| Duplicate search | 2026-09-24, see below |

**Title:** `cilium-cli: --flow-validation never matches the SYN-ACK of pod-to-service when the reply is reverse-NATed in bpf_lxc (Hubble reports it in SourceXlated)`

### Is there an existing issue for this?

- [x] I have searched the existing issues

Searched on 2026-09-24 in cilium/cilium and cilium/cilium-cli for
`"flow validation failed"`, `flow-validation strict`, `SourceXlated
connectivity`, `missing SYN-ACK`, `pod-to-service flow validation` and
`orbstack`. Related but not the same:

- cilium/cilium-cli#3255 (closed as stale, not planned, 2026-09-02): the
  same test fails with socket LB on (Talos, Cilium 1.19.5). There the
  SYN to the ClusterIP never appears, because the socket hook translates
  before any packet exists. This report is the tc-level LB case.
- cilium/cilium-cli#419 (closed as stale): a missing SYN-ACK on
  `pod-to-local-nodeport`.
- cilium/cilium-cli#52 (closed as stale): asks the test to fail when
  monitor aggregation is not `none`.
- cilium/cilium#16392, #16291 (2021, closed): CI flakes on the same test
  with older code.

### Version

equal or higher than 1.20.2 and lower than v1.21.0

### What happened?

`cilium connectivity test --flow-validation strict` fails
`no-policies`, `allow-all-except-world` and `pod-to-itself-via-service`
on their pod-to-service actions, although every request succeeds. The
SYN-ACK requirement is never met:

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
   and the service scenarios pass no `AltDstIP` for the backend
   ([service.go#L62](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/tests/service.go#L62)).

So no reply flow can ever match `src=<ClusterIP>`. A second, smaller
cause: with the chart's default `bpf.monitorAggregation: medium`,
`emit_trace_notify()` drops every `TRACE_FROM_*` event
([trace.h#L179-L194](https://github.com/cilium/cilium/blob/v1.20.2/bpf/lib/trace.h#L179-L194)),
so the pre-DNAT SYN (`from-endpoint`) is not reported either. With
`monitor-aggregation none` the SYN matches and only the SYN-ACK fails.

The same run also fails `to-fqdns` for a different reason: the test
expects an HTTP GET flow
([to_fqdns.go#L48](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/builder/to_fqdns.go#L48),
checked in [action.go#L757](https://github.com/cilium/cilium/blob/ef5d47de14d0/cilium-cli/connectivity/check/action.go#L757)),
but its policy `client-egress-to-fqdns.yaml` has no `http` rules, so the
traffic is never redirected to Envoy. Hubble shows
`policy-verdict:L3-L4` then `to-network`, which matches the policy.

Expected: the IP filter also accepts `IP.SourceXlated` (and
`DestinationXlated`) for service destinations, and `to-fqdns` expects an
HTTP flow only when its policy has an L7 rule.

### How can we reproduce the issue?

1. Install Cilium 1.20.2 with `kubeProxyReplacement: true` and
   `socketLB.hostNamespaceOnly: true`, so pods use tc-level Service
   translation. We use k0s 1.36.4 on one node, `bpf.datapathMode:
   netkit`, `bpf.masquerade: true`, Hubble Relay enabled.
2. `cilium hubble port-forward &`
3. `cilium connectivity test --hubble-server localhost:4245 --flow-validation strict --test no-policies,allow-all-except-world,pod-to-itself-via-service,to-fqdns`

### Cilium Version

```text
cilium-cli: v0.20.0 compiled with go1.27.0 on darwin/arm64
cilium image (running): v1.20.2
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

Unknown. Cilium's CI runs the connectivity test with
`--flow-validation=disabled` unless a job opts in
([cli-test-config/action.yaml](https://github.com/cilium/cilium/blob/main/.github/actions/cli-test-config/action.yaml)),
so these expectations are not exercised.

### Sysdump

Not attached. Available on request.

### Relevant log output

```text
❌ 4/79 tests failed (7/311 actions), 58 tests skipped, 0 scenarios skipped:
  🟥 no-policies/pod-to-service:curl-ipv4-0: ... Flow validation failed
  🟥 allow-all-except-world/pod-to-service:curl-ipv4-0: ... Flow validation failed
  🟥 pod-to-itself-via-service/pod-to-itself-via-service:curl-ipv4-0: ... Flow validation failed
  🟥 to-fqdns/pod-to-world:http-to-one.one.one.one.-ipv4-0: ... Flow validation failed
```

### Anything else?

The traffic in every failing action is correct: each connection
completes (`FORWARDED` SYN, SYN-ACK, data and FIN), and the same run
with `--flow-validation warning` passes all 79 tests.

### Cilium Users Document

- [ ] Are you a user of Cilium? Please add yourself to the [Users doc](https://github.com/cilium/cilium/blob/main/USERS.md)

### Code of Conduct

- [x] I agree to follow this project's Code of Conduct

### Notes for this repo (not part of the issue)

- `mise run cilium:conformance` runs `--flow-validation warning`: Hubble
  Relay must be reachable, and flow mismatches are logged in the run's
  output instead of failing it. Switch to `strict` once cilium-cli
  matches translated addresses and fixes the `to-fqdns` expectation.
- OrbStack is not the cause: #3255 fails the same test on Talos, and the
  mismatch is in the parser and CLI code above. It is linked to
  OrbStack only through `socketLB.hostNamespaceOnly: true`, which this
  repo sets because of the
  [OrbStack kernel request](../../modules/vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy).
  With socket LB on in pods the test still fails, as in #3255.
- `strict` would also need `bpf.monitorAggregation: none`, which raises
  event volume on every node; not worth it for a test alone.
- Evidence gathered 2026-09-24 with the versions above, OrbStack
  `2.2.3 (2020300)`, macOS 26.6.2 (arm64), Ubuntu 26.04.1.
