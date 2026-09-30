# cluster-access

## Abstract

How to reach one installed cluster: its name, API endpoint, kubeconfig (by `private-state` name) and the labels a fleet manager needs to adopt it (role, environment).

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the k0s installer (k0sctl).
- Consumers: the bootstrap, the delivery engine, the `verify` tasks, a later k0rdent adoption.
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- The kubeconfig is referenced by name; the file lives in private state.
