# firmament

Abstract: Declarative bootstrap for a dedicated Kubernetes host — one
OrbStack VM, verified Ubuntu-ready, running k0s with Cilium and Hubble.
`environment/local` composes four real OpenTofu modules under `modules/`
into one applied environment with a single shared state.

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
  `${XDG_STATE_HOME:-$HOME/.local/state}/firmament/environment/local/`.

## Setup

Install [mise](https://mise.jdx.dev/getting-started.html) itself first,
then install this repo's pinned tools and Git hooks:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
mise run hooks:install
```

Make the pinned tools and project environment (including `KUBECONFIG`)
available in your shell. Either activate mise persistently in your shell
profile — see mise's
[shell activation docs](https://mise.jdx.dev/getting-started.html#activate-mise) —
or, for a one-off shell session:

```sh
eval "$(mise env)"
```

## Structure

```text
environment/local/    root config: composes the four modules below,
                      owns the one shared state and the kubeconfig file
modules/vm-orb/       the OrbStack VM
modules/os-ubuntu/    Ubuntu readiness check (SSH probe + postconditions)
modules/cni-cilium/   the Cilium and Hubble Helm chart declaration
modules/orch-k0s/     the k0s controller+worker node, which installs
                      the declared Helm charts
```

Each module has its own README with its contract. `mise run env:apply`
applies the whole environment in dependency order (VM, then the readiness
check, then k0s, which installs Cilium); `mise run env:destroy`
reverses it. Narrower tasks
(`orb:apply`, `ubuntu:verify`, `k0s:apply`, and their counterparts) target
one module via `tofu -target` against the same shared state (`k0s:*` also
targets the kubeconfig file and renders the Cilium chart it depends on) —
see `environment/local/README.md` for the full task list and what
`-target` does and doesn't isolate.

`mise run check` runs formatting, linting, `tofu validate`, every
module's test suite, and the `environment/local` wiring tests.

Deferred work is tracked in [TODOS.md](TODOS.md).

## Uninstalling

To remove mise itself and everything it installed — **not scoped to this
project; this removes mise machine-wide**, including tool versions other
projects may depend on:

```sh
mise implode --dry-run   # list what would be removed, without removing it
mise implode             # remove the mise CLI and its installed tools/cache
mise implode --config    # also remove ~/.config/mise
```
