# vm-orb

Abstract: OpenTofu module declaring one OrbStack machine, using the
`robertdebock/orbstack` provider's `orbstack_machine` resource.

## Inputs

`name` (default `firmament`), `image` (default `ubuntu:resolute`), `arch`
(default `arm64`), `username` (default `tensor`) — see `variables.tf`.

## Outputs

`id`, `name`, `ip_address`, `status`, `dns_name`
(`<name>.orb.local`), `ssh_target` (the ordinary-user `user@name@orb`
form), `root_ssh` (an object with the `address`/`user`/`port` needed to
reach the machine as root through OrbStack's SSH multiplexer, for tools
like k0sctl that need root and can't use the `@orb` alias).

## Constraints

- OrbStack must be installed and running. This module was checked with
  `2.2.3`.
- **No cpu/memory/disk limits are declared.** `orbstack_machine` has no
  arguments for any of them, and the provider's only other relevant
  resource, `orbstack_config`, is app-wide (not per-machine) and reports
  an apply-time error on every apply. A created machine gets whatever
  OrbStack's own defaults are.
- **No adopt/import path.** Importing an existing machine into this
  provider's state leaves `arch`, `image`, and `username` unset, which
  makes the next `plan` want to destroy and recreate the real machine.
  `mise run orb:create` only creates a machine that doesn't already exist
  under that name; adopting an existing unmarked machine isn't supported.

## Commands

Run from the repo root — this module has no state or backend of its own;
see [`environment/local`](../../environment/local/README.md) for the
full task list and how `-target` scopes these to just this module:

| Command | Behavior |
| --- | --- |
| `mise run orb:create` | Create the machine (fails if a same-named machine already exists) |
| `mise run orb:dry-run` | Plan without applying |
| `mise run orb:delete` | Delete the machine, and anything that depends on it |
| `mise run orb:inspect` | Show the machine's native JSON metadata, unmanaged (bypasses OpenTofu entirely) |
| `mise run orb:test:unit` | Run this module's tests against a rendered plan, no live VM |

`mise run orb:create` prints the machine's native `orb info` JSON to
stdout after applying.

## Testing

Tests run `tofu plan` and inspect the JSON plan output. Plan makes no
live OrbStack calls — one test confirms this by removing `orb` from
`PATH` entirely and still passing.

See `BUGS.md` for a reproduced OrbStack CLI crash
(`orb delete <ID>` segfaults; `orb delete <name>` doesn't) and a kernel
request to enable `CONFIG_INET_DIAG_DESTROY`, which Cilium needs to close
sockets to deleted Service backends.

See the [OrbStack command reference](https://docs.orbstack.dev/machines/commands).
