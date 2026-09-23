# os-ubuntu

Abstract: OpenTofu module verifying a host is a ready k0s target — SSH
probe plus a set of `postcondition` assertions on a `data "external"`
resource. Fails `plan`/`apply` with a specific error message the moment a
requirement isn't met, before anything downstream touches the host.

## Inputs

`ssh_target` (required — `user@host`, or an OrbStack `user@machine@orb`
alias), `ssh_port`, `ssh_identity_file` (both optional).

## Output

`ready` — non-empty once every postcondition has passed. Reference this
from a dependent module (or just use a module-level `depends_on`, as
[`environment/local`](../../environment/local/README.md) does) to force
evaluation order.

## Contract

`scripts/probe.sh` is `data.external`'s `program`: it reads the query
(JSON on stdin), SSHes to `ssh_target`, and prints a flat JSON object of
facts (Ubuntu version, init system, cgroup version, kernel BTF,
passwordless sudo, `curl`/`systemctl` presence) — no assertions, those
live in `main.tf`'s `postcondition` blocks so the failure messages are
declared next to the contract, not buried in a script.

The readiness contract itself: Ubuntu `26.04`, `aarch64`/`arm64`/`x86_64`,
`systemd` as PID 1, cgroup v2, kernel BTF present, passwordless sudo,
`curl` and `systemctl` present.

`data` resources are read on every `plan`, not deferred to `apply` — so
this check runs, and can fail, at plan time. There's nothing to destroy:
it never installs, configures, or owns anything on the host.

## Commands

Run from the repo root — this module has no state or backend of its own;
see [`environment/local`](../../environment/local/README.md) for the
full task list:

| Command | Behavior |
| --- | --- |
| `mise run ubuntu:check` | Plan (runs the probe and every postcondition) |
| `mise run ubuntu:test` | Run this module's tests against a fixture SSH target, no live host |
