# OrbStack bootstrap

Abstract: Create the dedicated Ubuntu machine or explicitly adopt an existing
one. Track ownership by OrbStack machine ID and validate its configuration on
subsequent runs.

## Goals

- Declare the machine in `machine.json`, checked by `machine-schema.jq`.
- Keep creation, inspection, and adoption available through mise.
- Refuse accidental reuse of an unmarked or replaced machine.

## Constraints

- OrbStack is optional; existing Ubuntu hosts bypass these tasks.
- OrbStack must be installed and running. This workflow was checked with 2.2.3.
- These tasks own VM creation and its local ownership record only. They do not
  install guest packages, prepare Ubuntu, or provision Kubernetes.
- No task deletes, resizes, restarts, or reconfigures an existing VM.

## Commands

Install the pinned command-line dependencies and repository hooks:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
mise run hooks:install
```

| Command | Behavior |
| --- | --- |
| `mise run bootstrap:orb` | Create if absent; validate if already owned |
| `mise run orb:inspect` | Show the configured machine's native JSON metadata |
| `mise run orb:adopt` | Explicitly validate and record existing VM ownership |
| `mise run check` | Run formatting, ShellCheck, schema, and Bats checks |
| `mise exec -- hk check --all` | Run the hook checks against the checkout |

hk is pinned to 2.0.1. Its pre-commit hook runs ShellCheck and the Bats suite
through the same mise tasks used interactively. It checks staged content without
fixing or staging files; hk temporarily saves unstaged work during the hook.
Installation is repository-scoped and uses mise to resolve pinned tools.

The declared target is Ubuntu `resolute` on arm64 with 4 CPUs, 8192 MiB memory,
and a 40 GiB disk-usage limit. A configuration mismatch fails without modifying
the VM. The disk check uses OrbStack's limit, not the guest's shared filesystem
capacity.

Successful bootstrap/adoption prints native machine metadata as JSON to stdout.
Ownership messages and errors go to stderr. Command failures stop the task.

## Ownership and reruns

Ownership lives outside Git at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/orb/ownership.json
```

The file records the stable machine ID, not its IP address. An unmarked VM or a
same-name replacement requires explicit `orb:adopt`. Failed validation leaves
existing ownership unchanged. An owned VM that disappears is not silently
recreated; inspect the old ownership record before intentionally replacing it.

State is private to the local user. Tasks use an atomic ownership-file replacement
and a shared target lock so sibling worktrees cannot provision simultaneously.
If a process is forcibly killed, a stale `.lock` directory may remain. Remove
that empty directory only after confirming no bootstrap/adoption process is active.

Tests invoke the real scripts against a controlled OrbStack CLI fixture. They
exercise ownership writes, reruns, rejection paths, and command failures without
creating a VM. Scripts and matching Bats tests are colocated under `scripts/`
and `tests/`, with basenames matching their mise task names.

See the [OrbStack command reference](https://docs.orbstack.dev/machines/commands).
