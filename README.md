# firmament

Abstract: Declarative bootstrap for a dedicated Kubernetes host — one
OrbStack VM, verified Ubuntu-ready, running k0s with Cilium and Hubble.
`environment/local` composes three real OpenTofu modules under `modules/`
into one applied environment with a single shared state, then bootstraps
Flux, which runs Cilium and itself from `components/`.

## Goals

- Reproducible, idempotent bootstrap of one `firmament` target.
- Real OpenTofu modules, composed from one root config — not standalone
  scripts wired together by task ordering.
- Each module stays generic (host-agnostic where the underlying tool
  allows it); OrbStack-specific wiring lives in `environment/local`, not
  inside the modules themselves.

## Constraints

- mise is required. All pinned tool versions, tasks, and checks in this
  repo run through it — there is no supported path that bypasses mise.
- No mutable state or secrets are committed to Git. OpenTofu state and
  the rendered kubeconfig live under
  `$FIRMAMENT_STATE_HOME/environment/<env>/`, which defaults to
  `${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environment/<env>/`.

## Setup

Install [mise](https://mise.jdx.dev/getting-started.html) itself first,
then install this repo's pinned tools:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
```

`mise install` then runs `mise run repo:setup`, which installs the Git
hooks and trusts each `environment/<env>/mise.toml`. Run it again after
adding an environment.

Make the pinned tools and project environment (including `KUBECONFIG`)
available in your shell. `KUBECONFIG` points at the `local` cluster at the
repository root, and at each environment's own cluster inside
`environment/<env>/`. Either activate mise persistently in your shell
profile — see mise's
[shell activation docs](https://mise.jdx.dev/getting-started.html#activate-mise) —
or, for a one-off shell session:

```sh
eval "$(mise env)"
```

## Structure

```text
environment/local/    root config: composes the three modules below,
                      bootstraps Cilium and Flux, owns the one shared
                      state and the kubeconfig file
modules/vm-orb/       the OrbStack VM
modules/os-ubuntu/    Ubuntu readiness check (SSH probe + postconditions)
modules/orch-k0s/     the k0s controller+worker node; installs no charts
components/           packages Flux reconciles in the cluster (plain
                      Kustomize): cni-cilium (Cilium and Hubble) and
                      gitops-flux (Flux itself)
.mise/tasks/          one executable script per mise task, named
                      <noun>/<verb>.sh and run as `mise run <noun>:<verb>`
.mise/lib.sh          helpers the task scripts share (environment lookup,
                      state paths, the branch Flux follows, Flux build
                      rendering, post-apply waits), tested in .mise/tests
```

Each module and component has its own README with its contract.
`mise run env:apply` applies the whole environment in dependency order
(VM, then the readiness check, then k0s, then the bootstrap that installs
Cilium and Flux), and `mise run env:destroy` reverses it. Both take an
environment name, defaulting to `local`. Narrower tasks
(`orb:apply`, `ubuntu:verify`, `k0s:apply`, and their counterparts) target
one module via `tofu -target` against the same shared state (`k0s:*` also
targets the kubeconfig file) —
see `environment/local/README.md` for the full task list and what
`-target` does and doesn't isolate.

Task names follow `<noun>:<verb>` for a task that acts on one thing
(`shell:lint`, `k0s:apply`). A bare `<verb>` is an aggregate that runs
that verb for every noun. The verb also says how far a task reaches:

| Verb | Reach | Aggregate |
| --- | --- | --- |
| `lint`, `format` | files in the repository | `lint`, `format` run every `*:lint` or `*:format` |
| `test` | offline; never touches infrastructure | `test` runs every `*:test` |
| `verify` | reads a live cluster | `verify [environment]` runs every `*:verify`, one at a time, `env:verify` first |
| `conformance` | deploys test workloads into a live cluster | none |
| `e2e` | destroys and rebuilds a live cluster; asks first (`--yes` skips) | none |
| `plan`, `apply`, `destroy` | drive OpenTofu; `destroy` asks first (`-y` skips) | none |

`mise run check` runs every offline check: `lint` (shellcheck, shfmt,
`tofu fmt`, `mise fmt`, `mise tasks validate`, `chainsaw:lint` for the
live cluster suites, and `flux:lint`, which renders each environment's
Flux build with test runtime values through `flux envsubst --strict` and
validates it with `flux-schema` against the schemas vendored in
`.mise/flux-schemas`; `mise run flux:schemas` refreshes them from a pinned
flux-schema commit), `tofu:validate` and
`test` (every module and environment suite, and the task scripts with
their shared library). Suites that only check OpenTofu logic (rendered
values, variable validation, preconditions) are `tests/*.tftest.hcl`,
run by `tofu:test`. Suites that run shell or check OpenTofu's own error
output stay on bats (`tests/*.bats`). `mise run format` fixes what the
formatters can. hk defines the lint and format rules; the `*:lint` and
`*:format` tasks each run one group of its steps.

The Git hooks split the same checks by cost. `pre-commit` lints and
formats the staged files, fixing and restaging what it can. `pre-push`
adds `tofu:validate` and `test`, each only when the pushed commits touch
a file that can change its result.

Deferred work is tracked in [TODOS.md](TODOS.md).

### Worktrees

Create worktrees with [Worktrunk](https://worktrunk.dev):
`wt switch --create <branch>`. Its `pre-start` hook
([.config/wt.toml](.config/wt.toml)) runs `mise install` in the new
worktree; approve it once with `wt config approvals add`. For a plain
`git worktree add`, run `mise install` in the new worktree yourself. mise
shares trust with the main checkout, so no `mise trust` is needed.

Every worktree shares one state directory and one machine per
environment, so only one live cluster exists at a time. The tasks that
change an environment (`*:apply`, `*:destroy`, `env:e2e`,
`cilium:conformance`, `cilium:traffic-start`, `cilium:traffic-check`)
record the worktree that owns it, and refuse to
run from another worktree while the owner exists. Run the task from the
owning worktree, destroy the cluster there, or set
`FIRMAMENT_TAKE_OVER=1` to take it over.

The hooks are safe in linked worktrees. Git hands a
worktree's hooks `GIT_DIR`, `GIT_INDEX_FILE` and similar variables with
absolute paths. Every task clears them when it starts (`.mise/lib.sh`),
so tofu's module clones and `env:e2e` find the repository from their
working directory. The bats suite also seals git (`seal_git` in
`.mise/tests/stubs.bash`): it ignores your git config and allows only
local remotes, so its stand-in repositories can never commit, reset or
push in yours.

## Uninstalling

To remove mise itself and everything it installed — **not scoped to this
project; this removes mise machine-wide**, including tool versions other
projects may depend on:

```sh
mise implode --dry-run   # list what would be removed, without removing it
mise implode             # remove the mise CLI and its installed tools/cache
mise implode --config    # also remove ~/.config/mise
```
