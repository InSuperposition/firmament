# private-state

## Abstract

The files in an environment's private state directory (`$FIRMAMENT_STATE_HOME/environments/<env>/`): each file's name, path, mode (0600), producer, consumers, rotation, and the files it cannot be used without (the Raft snapshot needs the seal key it was taken under). It lists files; it never holds a value.

## Goals

- One definition of this data, checked by `mise run contracts:lint` (and so by `check`) wherever such a file appears.
- A change to the shape is a change to `schema.cue` and its sample in the same commit.

## Constraints

- Producer: whatever writes each file (the covenant bootstrap, the k0s installer, `env:destroy`).
- Consumers: every contract that names a credential (`environment-spec`, `machine-hosts`, `cluster-access`).
- Schema: `schema.cue`; a valid example: `samples/`. Which files must satisfy which definition is listed in `contracts/layout/layout.yaml` (`contract_files`).
- Local private state is development trust only: OrbStack machines can read the Mac's files.
- A file another file needs must itself be listed.
- Whether this contract can also describe a sops or fnox store is open.
