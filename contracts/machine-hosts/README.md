# machine-hosts

## Abstract

The machines a machine layer created, as the orchestrator reaches them: name, the machine's own address, the SSH endpoint, user and key name, and a k0s role hint. On OrbStack every machine shares the proxy `127.0.0.1:32222` and is told apart by the user `root@<machine>`.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: the machine layer (the `orb:apply` task on OrbStack); later the cloud and bare-metal roots.
- Consumers: the k0s installer (k0sctl).
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- The machine address, not its `.orb.local` name, is the API address.
- The key is referenced by its `private-state` name, never embedded.
