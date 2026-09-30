# environment-spec

## Abstract

The format of an environment: `environments/<env>/environment.yaml` (target, engine, artifact source, budget, clusters with their machines and service CIDR, mesh allocations, credentials by name), `tenants/<name>.yaml` and `deltas/<cluster>/<package>.yaml`.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the operator of each environment.
- Consumers: the machine tasks (machines and sizes), the k0s installer (k0sctl), the renderer (facts, tenants, deltas), `contracts:lint`.
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- Mesh allocations (id and pod CIDR per cluster) are append-only: `contracts:lint` compares them with `git show HEAD:<file>` and fails when one changed or disappeared. A retired cluster keeps its allocation.
- Mesh ids are unique; pod CIDRs overlap neither each other nor a service CIDR.
- The machines' memory and disk fit the budget; CPUs may be shared.
- A delta sets only keys its package lists in `delta_keys`, for a package its cluster runs, and states a reason.
- Credentials are named and located in `private-state`; this file never holds a value.
