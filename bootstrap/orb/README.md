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
- **No cpu/memory/disk limits are declared.** The provider has no
  arguments for any of them — not on `orbstack_machine`, and not
  per-machine anywhere (its `orbstack_config` resource is app-wide only,
  and even that throws apply-time errors — see
  `FIRMAMENT_FINDINGS.md` in the `opentofu-provider-orbstack` fork). A
  created machine gets whatever OrbStack's own defaults are. This is a
  real reduction versus the previous bash script's declared 4 CPU /
  8192 MiB / 40 GiB contract, not an oversight — fixing it is future work
  on the fork, tracked there.
- **No adopt/import path.** `tofu import` on this provider leaves `arch`,
  `image`, and `username` unset in state, which makes the very next
  `plan` want to destroy and recreate the real machine (verified,
  documented in the fork's findings, never applied). Until that's fixed
  upstream, adopting an existing unmarked machine isn't supported here —
  `mise run orb:create` only creates a machine that doesn't already exist
  under that name.

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
native `orb info` JSON to stdout after applying, matching the previous
script's output shape.

## State

OpenTofu's local state, not an ownership marker file, lives outside Git at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/orb/
```

OpenTofu's own state lock (held during `plan`/`apply`) is what now
prevents concurrent runs from sibling worktrees, replacing the previous
hand-rolled `.lock` directory.

Tests run `tofu plan` and inspect the JSON plan output — no live OrbStack
calls happen at plan time (verified: a test explicitly runs with `orb`
removed from `PATH` and still passes). Scripts don't exist for this stage
anymore; `.tf` files and matching Bats tests are colocated under
`bootstrap/orb/` and `tests/`, with test basenames matching their primary
mise task name.

See `bootstrap/orb/BUGS.md` for a reproduced OrbStack CLI crash found
while spiking this conversion (`orb delete <ID>` segfaults; `orb delete
<name>` doesn't — unrelated to the provider, not yet filed upstream).

See the [OrbStack command reference](https://docs.orbstack.dev/machines/commands).
