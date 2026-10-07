# firmament

Abstract: Declarative bootstrap for a dedicated Kubernetes host — one
OrbStack VM, verified Ubuntu-ready, running k0s with Cilium and Hubble.
Three OpenTofu roots under `roots/` compose the modules under `modules/`,
one concern each: the machine, k0s on it, then the bootstrap of Flux,
which runs Cilium and itself from `packages/`. Each root hands the next a
contract file.

## Goals

- Reproducible, idempotent bootstrap of one `firmament` target.
- Real OpenTofu modules, composed by roots that each declare one concern
  and hand the next root a contract file — not standalone scripts wired
  together by task ordering.
- Each module stays generic (host-agnostic where the underlying tool
  allows it); OrbStack-specific wiring lives in `roots/machine-orb`, not
  inside the modules themselves.

## Constraints

- mise is required. All pinned tool versions, tasks, and checks in this
  repo run through it — there is no supported path that bypasses mise.
- No mutable state or secrets are committed to Git. OpenTofu state and
  the rendered kubeconfig live under
  `$FIRMAMENT_STATE_HOME/environments/<env>/`, which defaults to
  `${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environments/<env>/`.
  `MISE_ENV` names the environment (`local` when unset); `mise.toml` derives
  `TF_VAR_state_directory` and `KUBECONFIG` from it, once.

## Setup

Install [mise](https://mise.jdx.dev/getting-started.html) itself first,
then install this repo's pinned tools:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
```

`mise install` then runs `mise run repo:setup`, which installs the Git
hooks and creates the shared OpenTofu provider cache.

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
roots/machine-orb/    the OrbStack machine and its readiness check;
                      writes the machine-hosts contract
roots/kubernetes-k0s/ renders k0sctl.yaml for that machine; a mise task
                      runs k0sctl; writes the cluster-access contract
                      with the runtime values
roots/bootstrap-flux/ bootstraps Cilium and Flux into the cluster
contracts/layout/     the layout contract: folders, what each may
                      reference, the review checks (C79)
contracts/machine-hosts/, cluster-access/, environment/
                      the data files that cross roots and tasks: closed
                      schemas, checked offline by contracts:lint and by
                      the root that reads each file
contracts/package-spec/, cluster-spec/, bindings-spec/, tenant-spec/, delta-spec/
                      the formats of the files authors write; the Timoni
                      modules that read them check them again
clusters/singularity/ the cluster definition: its Flux build (which
                      packages Flux applies) and its cluster suite
environments/local/   the local environment's data: environment.yaml names
                      its cluster; its upgrade checks and mise.toml
modules/vm-orb/       the OrbStack VM
modules/os-ubuntu/    Ubuntu readiness check (SSH probe + postconditions)
modules/orch-k0s/     the k0s controller+worker node; installs no charts
packages/cilium/      Cilium and Hubble, as Flux reconciles them (plain Kustomize)
packages/flux/        Flux itself (Flux Operator and the FluxInstance)
.mise/tasks/          one executable script per mise task, named
                      <noun>/<verb>.sh and run as `mise run <noun>:<verb>`
.mise/lib.sh          helpers the task scripts share (environment lookup,
                      state paths, the branch Flux follows, Flux build
                      rendering, post-apply waits), tested in .mise/tests
```

Each module and package has its own README with its contract.
`mise run env:apply` applies the three roots in order (the machine and its
readiness check, then k0s, then the bootstrap that installs Cilium and
Flux), and `mise run env:destroy` destroys the Kubernetes root, then the
machine root; the bootstrap's objects go with the machine. Both act on the
environment `MISE_ENV` names, `local` when unset. Narrower tasks act on one root:
`orb:*` and `ubuntu:verify` on the machine root, `k0s:*` on the Kubernetes
root. See `environments/local/README.md` for the full task list.

Task names follow `<noun>:<verb>` for a task that acts on one thing
(`shell:lint`, `k0s:apply`). A bare `<verb>` is an aggregate that runs
that verb for every noun. The verb also says how far a task reaches:

| Verb | Reach | Aggregate |
| --- | --- | --- |
| `lint`, `format` | files in the repository | `lint`, `format` run every `*:lint` or `*:format` |
| `test` | offline; never touches infrastructure | `test` runs every `*:test` |
| `verify` | reads a live cluster | `verify` runs every `*:verify`, one at a time, `env:verify` first; `--only <packages>` keeps the environment's own checks and the chosen packages', and `--changed` chooses the packages the branch changed |
| `ui`, `observe` | read a live cluster through a foreground port-forward that Ctrl-C stops; `ui` opens the browser and takes `--port` | none |
| `conformance` | deploys test workloads into a live cluster | `conformance` runs every `*:conformance`, one at a time; `--only <packages>` or `--changed` runs the tests each package lists in `tests/conformance` |
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
cluster itself, and each package has one for its own workloads.

`timoni` renders the cluster and environment artifacts and is still before
version 1.0, so `mise.toml` pins it exactly. Upgrade it only by rerunning
the render and refusal checks against the new version, and regenerate the
core schemas each module vendors in the same change.
`env:verify` runs the environment's suite, then the suite of every
package the environment's Flux build lists. A package's name is its
folder name (`packages/cilium` is `cilium`), which is also the noun of
its tasks (`cilium:verify`).
`verify --only cilium,flux` checks only those packages, plus the
environment itself. `verify --changed` chooses the packages from what the
branch changed since it left `origin/main`: a change under
`packages/<name>/` selects that package, Markdown selects nothing, and any
other change selects every package. `mise run format` fixes what the
formatters can. hk defines the lint and format rules; the `*:lint` and
`*:format` tasks each run one group of its steps.

The Git hooks split the same checks by cost. `pre-commit` lints and
formats the staged files, fixing and restaging what it can. `pre-push`
adds `tofu:validate` and `test`, each only when the pushed commits touch
a file that can change its result.

Deferred work is planned in `.plan/`, a local folder that Git ignores:
start with `.plan/README.md`. `TODOS.md` lists small follow-ups found while
building, each with its context.

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
`cilium:conformance`, `cilium:restart-agent`, `cilium:traffic-start`,
`cilium:traffic-check`)
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
