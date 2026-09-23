# OrbStack bootstrap

Abstract: Create or delete the dedicated OrbStack machine through OpenTofu,
using the `robertdebock/orbstack` provider's `orbstack_machine` resource.

## Goals

- Declare the machine directly in `bootstrap/orb/*.tf` — no separate
  schema file, OpenTofu's own typed resource arguments are the schema.
- Keep creation and deletion available through mise, matching `orb`'s own
  CLI vocabulary (`create`/`delete`).

## Constraints

- OrbStack is optional; existing Ubuntu hosts bypass this stage entirely.
- OrbStack must be installed and running. This workflow was checked with
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

Install the pinned command-line dependencies and repository hooks:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
mise run hooks:install
```

| Command | Behavior |
| --- | --- |
| `mise run orb:create` | Create the machine (fails if a same-named machine already exists — see the adopt constraint above) |
| `mise run orb:dry-run` | Plan without applying |
| `mise run orb:delete` | Delete the machine |
| `mise run orb:inspect` | Show the machine's native JSON metadata, unmanaged |
| `mise run check` | Run formatting, ShellCheck, `tofu fmt`/`validate`, and Bats checks |
| `mise exec -- hk check --all` | Run the hook checks against the checkout |

The declared target is Ubuntu `resolute` on arm64, username `tensor` —
`bootstrap/orb/machine.tf`. `mise run orb:create` prints the machine's
native `orb info` JSON to stdout after applying.

## State

OpenTofu's local state lives outside Git at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/orb/
```

OpenTofu's own state lock, held during `plan`/`apply`, prevents concurrent
runs from sibling worktrees.

Tests run `tofu plan` and inspect the JSON plan output. Plan makes no
live OrbStack calls. `.tf` files and matching Bats tests are colocated
under `bootstrap/orb/` and `tests/`, with test basenames matching their
primary mise task name.

See `bootstrap/orb/BUGS.md` for a reproduced OrbStack CLI crash
(`orb delete <ID>` segfaults; `orb delete <name>` doesn't).

See the [OrbStack command reference](https://docs.orbstack.dev/machines/commands).
