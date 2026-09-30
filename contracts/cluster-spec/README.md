# cluster-spec

## Abstract

The format of `clusters/<cluster>/cluster.yaml` (role, mesh membership, the tenant kinds its shared services admit, cluster-level `requires` and `provides`) and `clusters/<cluster>/packages.yaml` (the packages the cluster runs, an unordered set with `bootstrap` markers). Owns `#Role` and `#TenantKind`.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the author of each cluster.
- Consumers: `environment-spec` (tenant kinds), `cluster-access` (role label), `contracts:lint`, the renderer.
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- A cluster file never names an environment and holds no environment fact (sizes, addresses, CIDRs); `layout:lint` enforces both.
- Order comes from `requires` and `provides`, never from the order of `packages.yaml`.
- New tenant kinds are added to the enum; existing data keeps its meaning.
