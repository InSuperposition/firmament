# vm-orb

Abstract: OpenTofu module declaring one OrbStack machine, using the
`robertdebock/orbstack` provider's `orbstack_machine` resource.

## Inputs

`name` (required) and `image` (default `ubuntu:resolute`) — see
`variables.tf`. No architecture or user is pinned: OrbStack picks them for
the host it runs on.

## Outputs

`id`, `name`, `ip_address`, `status`, `dns_name` (`<name>.orb.local`),
`ssh_target` (`<name>@orb`, the host's default user through OrbStack's SSH
alias) and `ssh`: how a tool that needs root, such as k0sctl, reaches the
machine through OrbStack's multiplexer. `ssh` holds the `address`, `port`,
`user` (`root@<name>`), OrbStack's client `key_path` and `host_keys`, the
multiplexer's server keys read from `~/.orbstack/ssh/known_hosts` as
`<type> <base64 key>` entries. Reading `~/.orbstack` is why only this
module knows OrbStack. When no key is found for `[127.0.0.1]:32222`, the
`ssh` output fails and names the file.

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
  `mise run orb:apply` only creates a machine that doesn't already exist
  under that name; adopting an existing unmarked machine isn't supported.

## Commands

Run from the repo root — this module has no state or backend of its own;
see [`environments/local`](../../environments/local/README.md) for the
full task list; these tasks run the machine root, which composes this
module:

| Command | Behavior |
| --- | --- |
| `mise run orb:apply` | Create the machine (fails if a same-named machine already exists) |
| `mise run orb:plan` | Plan without applying |
| `mise run orb:destroy` | Delete the machine, and anything that depends on it |
| `mise run orb:inspect` | Show the machine's native JSON metadata, read from OrbStack directly; OpenTofu only supplies the machine name from state |
| `mise run orb:test` | Run this module's tests against a rendered plan, no live VM |

`mise run orb:apply` prints the machine's native `orb info` JSON to
stdout after applying.

## Testing

Tests run `tofu plan` with `HOME` set to a fixture directory holding OrbStack's `known_hosts`, and inspect the JSON plan output. Plan makes no
live OrbStack calls — one test confirms this by removing `orb` from
`PATH` entirely and still passing.

See `BUGS.md` for a reproduced OrbStack CLI crash
(`orb delete <ID>` segfaults; `orb delete <name>` doesn't) and a kernel
request to enable `CONFIG_INET_DIAG_DESTROY`, which Cilium needs to close
sockets to deleted Service backends.

See the [OrbStack command reference](https://docs.orbstack.dev/machines/commands).
