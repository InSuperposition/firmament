# firmament

Abstract: Declarative bootstrap for a dedicated Kubernetes host — one
OrbStack VM, verified Ubuntu-ready, running k0s with Cilium and Hubble.
`environments/local` composes three real OpenTofu modules under `modules/`
into one applied environment, then a second root with its own state
bootstraps Flux, which runs Cilium and itself from `packages/`.

## Goals

- Reproducible, idempotent bootstrap of one `firmament` target.
- Real OpenTofu modules, composed from one root config — not standalone
  scripts wired together by task ordering.
- Each module stays generic (host-agnostic where the underlying tool
  allows it); OrbStack-specific wiring lives in `environments/local`, not
  inside the modules themselves.

## Constraints

- mise is required. All pinned tool versions, tasks, and checks in this
  repo run through it — there is no supported path that bypasses mise.
- No mutable state or secrets are committed to Git. OpenTofu state and
  the rendered kubeconfig live under
  `$FIRMAMENT_STATE_HOME/environments/<env>/`, which defaults to
  `${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environments/<env>/`.

## Setup

Install [mise](https://mise.jdx.dev/getting-started.html) itself first,
then install this repo's pinned tools:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
```

`mise install` then runs `mise run repo:setup`, which installs the Git
hooks and trusts each `environments/<env>/mise.toml`. Run it again after
adding an environment.

Make the pinned tools and project environment (including `KUBECONFIG`)
available in your shell. `KUBECONFIG` points at the `local` cluster at the
repository root, and at each environment's own cluster inside
`environments/<env>/`. Either activate mise persistently in your shell
profile — see mise's
[shell activation docs](https://mise.jdx.dev/getting-started.html#activate-mise) —
or, for a one-off shell session:

```sh
eval "$(mise env)"
```

## Structure

```text
environments/local/    root config: composes the three modules below,
                      owns the environment's state and the kubeconfig
                      file and the runtime values
environments/local/bootstrap/
                      root config applied after it, with its own state:
                      bootstraps Cilium and Flux into the cluster
modules/vm-orb/       the OrbStack VM
modules/os-ubuntu/    Ubuntu readiness check (SSH probe + postconditions)
modules/orch-k0s/     the k0s controller+worker node; installs no charts
packages/           packages Flux reconciles in the cluster (plain
                      Kustomize): cni-cilium (Cilium and Hubble) and
                      gitops-flux (Flux itself)
.mise/tasks/          one executable script per mise task, named
                      <noun>/<verb>.sh and run as `mise run <noun>:<verb>`
.mise/lib.sh          loads the helpers the task scripts share from
                      .mise/lib/ (git, state, environment, tofu, flux,
                      chainsaw, waits), tested in .mise/tests; a package's
                      own helpers live in packages/<name>/lib/
```

Each module and component has its own README with its contract.
`mise run env:apply` applies the whole environment in dependency order
(VM, then the readiness check, then k0s, then the bootstrap root that
installs Cilium and Flux), and `mise run env:destroy` destroys the
environment root; the bootstrap's objects go with the machine. Both take an
environment name, defaulting to `local`. Narrower tasks
(`orb:apply`, `ubuntu:verify`, `k0s:apply`, and their counterparts) target
one module via `tofu -target` against the same shared state (`k0s:*` also
targets the kubeconfig file) —
see `environments/local/README.md` for the full task list and what
`-target` does and doesn't isolate.

Task names follow `<noun>:<verb>` for a task that acts on one thing
(`shell:lint`, `k0s:apply`). A bare `<verb>` is an aggregate that runs
that verb for every noun. The verb also says how far a task reaches:

| Verb | Reach | Aggregate |
| --- | --- | --- |
| `lint`, `format` | files in the repository | `lint`, `format` run every `*:lint` or `*:format` |
| `test` | offline; never touches infrastructure | `test` runs every `*:test` |
| `verify` | reads a live cluster | `verify [environment]` runs every `*:verify`, one at a time, `env:verify` first; `--only <modules>` keeps the environment's own checks and the chosen modules', and `--changed` chooses the modules the branch changed |
| `ui`, `observe` | read a live cluster through a foreground port-forward that Ctrl-C stops; `ui` opens the browser and takes `--port` | none |
| `conformance` | deploys test workloads into a live cluster | `conformance [environment]` runs every `*:conformance`, one at a time; `--only <modules>` or `--changed` runs the tests each module lists in `tests/conformance` |
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
output stay on bats (`tests/*.bats`). Read-only checks of a live cluster
are chainsaw suites in `tests/cluster/`: each environment has one for the
cluster itself, and each component has one for its own workloads.
`env:verify` runs the environment's suite, then the suite of every
component the environment's Flux build lists. A component's module name is
its folder name without the role prefix (`packages/cni-cilium` is
`cilium`), which is also the noun of its tasks (`cilium:verify`).
`verify --only cilium,flux` checks only those modules, plus the
environment itself. `verify --changed` chooses the modules from what the
branch changed since it left `origin/main`: a change under
`packages/<name>/` selects that module, Markdown selects nothing, and any
other change selects every module. `mise run format` fixes what the
formatters can. hk defines the lint and format rules; the `*:lint` and
`*:format` tasks each run one group of its steps.

The Git hooks split the same checks by cost. `pre-commit` lints and
formats the staged files, fixing and restaging what it can. `pre-push`
adds `tofu:validate` and `test`, each only when the pushed commits touch
a file that can change its result.

Deferred work is planned in `.plan/`, a local folder that Git ignores:
start with `.plan/README.md`. The last tracked list is
`git show b6dd6cd:TODOS.md`.

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
