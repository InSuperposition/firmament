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
| Related OrbStack request | [vm-orb/BUGS.md](../vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy) |

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

- `mise run cilium:connectivity` passes `--log-check-only-test-time`, so
  the start-up error does not fail the suite, while agent errors logged
  during the tests still do. Remove the flag once either this fix or the
  [OrbStack kernel request](../vm-orb/BUGS.md#kernel-request-enable-config_inet_diag_destroy)
  lands.
- Evidence gathered 2026-09-23 with Cilium 1.20.2, OrbStack
  `2.2.3 (2020300)`, macOS 26.6.2 (arm64), Ubuntu 26.04.1, k0s
  `1.36.4+k0s.0`, single node.
