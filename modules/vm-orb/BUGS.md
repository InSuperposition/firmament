# Upstream bugs: OrbStack

Abstract: Bug reports and feature requests against
[orbstack/orbstack](https://github.com/orbstack/orbstack) found while
running this module. Each report follows OrbStack's issue templates
([bug report](https://github.com/orbstack/orbstack/blob/main/.github/ISSUE_TEMPLATE/bug_report.yml),
[feature request](https://github.com/orbstack/orbstack/blob/main/.github/ISSUE_TEMPLATE/feature_request.md)),
so its title and body can be pasted into a new issue unchanged.

## Goals

- Keep every upstream report ready to file, with evidence reproducible
  from this repo.
- Record how each report affects this repo until upstream resolves it.

## Constraints

- Reports are filed by the repo owner. Nothing here has been filed yet.
- OrbStack's bug form asks for a private diagnostic report. Generate it
  with `orb report` at filing time; it is not stored here.
- Re-run the duplicate search before filing; the searches below are dated.

## CLI bug: `orb delete <ID>` crashes

| Field | Value |
| --- | --- |
| Repository | [orbstack/orbstack](https://github.com/orbstack/orbstack/issues/new?template=bug_report.yml) |
| Template | Bug report (`t/bug`) |
| Status | Not filed |
| Duplicate search | 2026-09-23: `orb delete ID`, `orb delete nil pointer`, `orb delete panic`, `delete.go panic`; no match |

**Title:** `orb delete <machine ID> panics with nil pointer dereference; deleting by name works`

### Describe the bug

`orb delete` documents its argument as `[ID/NAME]...`, but passing a
machine's ID crashes the CLI with a nil pointer dereference in
`scon/cmd/scli/cmd/delete.go:141`. The command exits with code 2 and the
machine is not deleted. Passing the machine's name works.

```text
panic: runtime error: invalid memory address or nil pointer dereference [recovered, repanicked]
[signal SIGSEGV: segmentation violation code=0x2 addr=0x10 pc=0x102573828]

goroutine 1 [running]:
github.com/orbstack/macvirt/vmgr/util/errorx.RecoverCLI(0x1)
	github.com/orbstack/macvirt/vmgr@v0.0.0-00010101000000-000000000000/util/errorx/errorx.go:30 +0x7c
panic({0x102cb3a60?, 0x102e26d50?})
	runtime/panic.go:860 +0x100
github.com/orbstack/macvirt/scon/cmd/scli/cmd.init.func47(0x102e42780, {0x2469e9039700, 0x1, 0x1026aff03?})
	github.com/orbstack/macvirt/scon/cmd/scli/cmd/delete.go:141 +0x868
github.com/spf13/cobra.(*Command).execute(0x102e42780, {0x2469e90396c0, 0x2, 0x2})
	github.com/spf13/cobra@v1.9.1/command.go:1015 +0x814
github.com/spf13/cobra.(*Command).ExecuteC(0x102e3d240)
	github.com/spf13/cobra@v1.9.1/command.go:1148 +0x350
github.com/spf13/cobra.(*Command).Execute(...)
	github.com/spf13/cobra@v1.9.1/command.go:1071
github.com/orbstack/macvirt/scon/cmd/scli/cmd.Execute(...)
	github.com/orbstack/macvirt/scon/cmd/scli/cmd/root.go:73
main.runCtl(0xe8?)
	github.com/orbstack/macvirt/scon/cmd/scli/main.go:144 +0x1bc
main.main()
	github.com/orbstack/macvirt/scon/cmd/scli/main.go:45 +0x84
```

### To Reproduce

```sh
orb create --arch arm64 ubuntu:resolute delete-test-a
orb create --arch arm64 ubuntu:resolute delete-test-b

orb delete -f delete-test-a                  # by name: exits 0, machine deleted
orb info delete-test-b                       # note the machine ID, e.g. 01M36DZYG0SWC1GAVAB87ATFZQ
orb delete -f 01M36DZYG0SWC1GAVAB87ATFZQ     # by ID: panics, exit code 2
orb list                                     # delete-test-b still exists
orb delete -f delete-test-b                  # by name: works
```

### Expected behavior

`orb delete <ID>` deletes the machine, the same as `orb delete <name>`,
as `orb delete --help` documents (`[ID/NAME]...`). If an ID cannot be
resolved, the CLI prints an error instead of panicking.

### Diagnostic report (REQUIRED)

Run `orb report` and paste the output here when filing.

### Screenshots and additional context (optional)

- OrbStack `2.2.3 (2020300)`, macOS 26.6.2, Apple Silicon (arm64).
- Reproduced 2026-09-23. The crash happens before deletion completes, so the
  machine is left intact.

### Notes for this repo (not part of the issue)

`modules/vm-orb` does not hit this bug. The `robertdebock/orbstack`
provider's `orbstack_machine` resource uses the machine's name as its
`id`, so its delete call takes the name-based path. That is a property of
the provider, not a deliberate workaround; if the provider ever switches
to the real OrbStack ID, `env:destroy` would hit this crash.

## Kernel request: enable CONFIG_INET_DIAG_DESTROY

| Field | Value |
| --- | --- |
| Repository | [orbstack/orbstack](https://github.com/orbstack/orbstack/issues/new?template=feature_request.md) |
| Template | Feature request (`t/feature`) |
| Status | Not filed |
| Duplicate search | 2026-09-23: `INET_DIAG_DESTROY`, `INET_DIAG`, `socket destroy`, `sock_destroy`, `netkit`, `cilium`, `kernel config`; no match |
| Related Cilium bug | [cni-cilium/BUGS.md](../cni-cilium/BUGS.md#socket-termination-disabled-when-only-the-netlink-destroy-path-is-missing) |

**Title:** `[Kernel] Enable CONFIG_INET_DIAG_DESTROY (socket termination for Cilium and ss -K)`

**Is your feature request related to a problem? Please describe.**

The OrbStack kernel builds socket diagnostics (`CONFIG_INET_DIAG=y`,
`CONFIG_INET_TCP_DIAG=y`, `CONFIG_INET_UDP_DIAG=y`,
`CONFIG_INET_RAW_DIAG=y`) but not `CONFIG_INET_DIAG_DESTROY`, which lets
privileged processes close other processes' sockets through the netlink
`SOCK_DESTROY` request.

```console
$ zcat /proc/config.gz | grep -E "INET_(TCP_|UDP_|RAW_)?DIAG"
CONFIG_INET_DIAG=y
CONFIG_INET_TCP_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_INET_RAW_DIAG=y
$ uname -r
7.0.14-orbstack-00380-ga7e0a2dc9535
```

Two things break without it:

1. **Cilium with kube-proxy replacement.** Cilium closes sockets
   connected to deleted Service backends, so applications reconnect to a
   live backend. Cilium 1.20 checks for `SOCK_DESTROY` at start-up, logs
   an error, and disables the feature. `cilium connectivity test` then
   fails its log check. In practice, a pod with a connected UDP socket
   (for example a DNS client) stays pinned to a deleted backend:

   ```text
   level=error msg="Forcefully terminating sockets connected to deleted service backends not supported by underlying kernel" module=agent.controlplane.loadbalancer-reconciler.socket-termination error="failed while iterating sockets: not supported: operation to destroy probe socket is unsupported. This likely means that kernel CONFIG_INET_DIAG_DESTROY must be set in order for this functionality to work"
   ```

   Cilium documents `CONFIG_INET_DIAG`, `CONFIG_INET_UDP_DIAG` and
   `CONFIG_INET_DIAG_DESTROY` as required for this feature in its
   [kube-proxy replacement guide](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/).

2. **`ss -K` silently does nothing.** `ss --kill` exits 0 but leaves the
   socket open:

   ```console
   $ ss -tn dst 127.0.0.1:7000
   ESTAB 0      0          127.0.0.1:53574    127.0.0.1:7000
   $ ss -K -tn dst 127.0.0.1:7000; echo "exit=$?"
   State Recv-Q Send-Q Local Address:Port Peer Address:Port
   exit=0
   $ ss -tn dst 127.0.0.1:7000 | tail -n +2 | wc -l
   1
   ```

**Describe the solution you'd like**

Build the kernel with `CONFIG_INET_DIAG_DESTROY=y`. It depends only on
`CONFIG_INET_DIAG`, which is already built in. It adds no work on any
socket path: it only adds the handler for an explicit, privileged
(`CAP_NET_ADMIN`) destroy request. Kernel help text
([net/ipv4/Kconfig](https://github.com/torvalds/linux/blob/v7.0/net/ipv4/Kconfig)):

> Provides a SOCK_DESTROY operation that allows privileged processes
> (e.g., a connection manager or a network administration tool such as
> ss) to close sockets opened by other processes.

Major distribution and platform kernels already enable it:

- Arch Linux: `CONFIG_INET_DIAG_DESTROY=y`
  ([config.x86_64](https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/blob/main/config.x86_64))
- Fedora: `CONFIG_INET_DIAG_DESTROY=y`
  ([kernel-x86_64-fedora.config](https://src.fedoraproject.org/rpms/kernel/blob/rawhide/f/kernel-x86_64-fedora.config))
- Android GKI: `CONFIG_INET_DIAG_DESTROY=y`
  ([gki_defconfig](https://android.googlesource.com/kernel/common/+/refs/heads/android-mainline/arch/arm64/configs/gki_defconfig))

**Describe alternatives you've considered**

- Cilium's BPF socket destroyer, which uses the `bpf_sock_destroy` kfunc
  and already works on this kernel. Cilium 1.20 disables the whole
  feature when the netlink check fails, so it never reaches that path.
  That is being reported to Cilium separately. Enabling this option fixes
  Cilium today, and fixes `ss -K` and other netlink users regardless.
- Disabling Cilium's socket-level load balancing. This loses connect-time
  Service translation for every pod, which is worse than the stale-socket
  problem.
- A custom kernel. OrbStack does not support custom kernels.

**Additional context**

- OrbStack `2.2.3 (2020300)`, macOS 26.6.2, Apple Silicon (arm64);
  Ubuntu 26.04.1 machine; Cilium 1.20.2 on k0s 1.36.4.
- Similar single-option requests were accepted before:
  `CONFIG_NET_ACT_POLICE` (#2326, added in v2.1.1) and
  `CONFIG_CRYPTO_ADIANTUM` (#2563, added in v2.2.2). Cilium on OrbStack
  was previously unblocked by a module fix (#1345).

### Notes for this repo (not part of the issue)

- Once this ships, remove `--log-check-only-test-time` from
  `cilium:conformance` in `mise.toml`, reconsider
  `socketLB.hostNamespaceOnly` in `modules/cni-cilium`, and update the
  socket termination section in
  [modules/cni-cilium/README.md](../cni-cilium/README.md#socket-termination).
- Unlike `CONFIG_PSI` (#1309, declined for measured performance
  regressions), this option does nothing until a privileged process
  sends a destroy request.
