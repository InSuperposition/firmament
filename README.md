# firmament

Abstract: Declarative bootstrap for a dedicated Kubernetes host — from the
OrbStack VM, through Ubuntu readiness verification, to a running k0s
cluster. Each stage is documented and tested independently under
`bootstrap/`.

## Goals

- Reproducible, idempotent bootstrap of one `firmament` target.
- Every stage owns only what it declares — no stage reaches ahead into the
  next one's responsibility.
- Prefer real declarative tooling (OpenTofu + providers, CUE) over
  hand-rolled imperative scripts wherever a real fit exists.

## Constraints

- mise is required. All pinned tool versions, tasks, and checks in this
  repo run through it — there is no supported path that bypasses mise.
- No mutable state or secrets are committed to Git. Ownership markers,
  OpenTofu state, and kubeconfigs live under
  `${XDG_STATE_HOME:-$HOME/.local/state}/firmament/`.

## Setup

Install [mise](https://mise.jdx.dev/getting-started.html) itself first,
then install this repo's pinned tools and Git hooks:

```sh
MISE_LOCKED_SCOPES=project mise install --locked
mise run hooks:install
```

Make the pinned tools and project environment (including `KUBECONFIG` for
the k0s stage) available in your shell. Either activate mise persistently
in your shell profile — see mise's
[shell activation docs](https://mise.jdx.dev/getting-started.html#activate-mise) —
or, for a one-off shell session:

```sh
eval "$(mise env)"
```

## Stages

Run in order; each has its own README with the full contract:

1. [`bootstrap/orb`](bootstrap/orb/README.md) — create or adopt the
   dedicated OrbStack VM.
2. [`bootstrap/ubuntu`](bootstrap/ubuntu/README.md) — verify the host
   meets the k0s readiness contract.
3. [`bootstrap/k0s`](bootstrap/k0s/README.md) — declare and apply the k0s
   `controller+worker` node via OpenTofu.

`mise run check` runs every stage's formatting, linting, schema, and test
checks.

## Uninstalling

To remove mise itself and everything it installed — **not scoped to this
project; this removes mise machine-wide**, including tool versions other
projects may depend on:

```sh
mise implode --dry-run   # list what would be removed, without removing it
mise implode             # remove the mise CLI and its installed tools/cache
mise implode --config    # also remove ~/.config/mise
```
