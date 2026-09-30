# environment-facts

## Abstract

The typed variables layer 3 supplies to one cluster's render: cluster name, mesh id, pod and service CIDR, API address and port, enrolled clusters, covenant addresses, machine sizes. Owns the address, CIDR, mesh id and size types.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the renderer, from `environment.yaml` and the machine layer's outputs.
- Consumers: the renderer, which turns each fact into a string for Flux substitution; every package that substitutes a fact.
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- A package that needs a new fact adds it to `#Facts` in the same change.
- Facts are variables only; they never override a value.
