# package-spec

## Abstract

The format of `packages/<package>/package.yaml`: what a package is (name, layer, pinned source, namespace), what it requires and provides, whether it is bootstrapped, and which values keys an environment delta may set. Owns the pin shape `#Pin` and the capability types every contract uses.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the author of each package.
- Consumers: `cluster-spec` (capabilities), `contracts:lint` (requirements, cycles, delta keys), the renderer.
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- A requirement names a capability, never a cluster. Scope `cluster` (default) is met by a package of the same cluster; scope `mesh` by another cluster of the environment. Each is met exactly once.
- A provider states its readiness check (`ready`), so an order derived from requirements means ready, not merely created.
- Packages must not depend on each other in a cycle.
