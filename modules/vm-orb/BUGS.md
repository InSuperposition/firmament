# OrbStack CLI bug: `orb delete <ID>` crashes

Reproduced 2026-09-23, OrbStack `2.2.3 (2020300)`, macOS (arm64).

## Repro

```sh
orb create --arch arm64 ubuntu:resolute delete-test-a
orb create --arch arm64 ubuntu:resolute delete-test-b

orb delete -f delete-test-a          # deletes by NAME — works
orb delete -f 01M36DZYG0SWC1GAVAB87ATFZQ   # deletes by ID — crashes
```

## Result

Deleting by name succeeds (exit 0). Deleting by the machine's own real ID
(the ULID `orb info` reports, e.g. `01M36DZYG0SWC1GAVAB87ATFZQ`) crashes
with a nil pointer dereference:

```
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

Exit code 2. The machine being deleted is left running/existing (the crash
happens before deletion completes) — confirmed by re-listing machines
afterward and deleting it successfully by name instead.

`orb delete --help` documents the argument as `[ID/NAME]...`, i.e. both
forms are meant to be supported. Only the name form works.

## Relevance to this repo

`modules/vm-orb/*.tf` (the `robertdebock/orbstack` OpenTofu provider) sidesteps
this entirely — its `orbstack_machine` resource's `id` attribute is the
machine's *name*, not its real OrbStack ULID, so its `Delete` call ends up
going through the safe name-based path by accident, not by design.

## Status

Not yet filed upstream — planned to be filed as a GitHub issue against
OrbStack directly by the repo owner.
