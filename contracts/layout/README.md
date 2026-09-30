# layout

## Abstract

`layout.yaml` describes the repository's top-level folders: what each one holds, what it may reference, and where a cluster name may appear. `schema.cue` is its schema. `mise run layout:lint` validates the data against the schema, then fails on any file that breaks a rule. `mise run lint` and `mise run check` include it.

## Goals

- Keep packages reusable. A package never names a cluster or an environment, and never holds a literal environment fact.
- Keep code out of environments. An environment is data: facts, tenants, deltas and declarative tests.
- Make a cluster rename a finite, listed change.

## Constraints

- Producer: this folder. Consumer: the `layout:lint` task (`.mise/tasks/layout/lint.sh`).
- The rules read only files git tracks or would track. Ignored build output never counts.
- The name and fact rules read data files only (`data_extensions`). Prose and test inputs may quote addresses and names.

## Rules

| Rule | Fails when |
| --- | --- |
| `environments-no-code` | A file under `environments/` has a code extension or is executable, and no exception covers it |
| `no-names` | A data file under `packages/` or `clusters/` holds a cluster or environment name |
| `roots-no-names` | A data file under `roots/` holds a cluster or environment name |
| `no-facts` | A data file under `packages/` or `clusters/` holds an IPv4 address, a CIDR or a size, other than the values in `fact_allow` |
| `packages-not-executable` | A file under `packages/` is executable |
| `task-folder-pairs-package` | A `.mise/tasks/<x>/` folder whose name matches `package_pattern` has no `packages/<x>/` |
| `modules-no-references` | A code file under `modules/` references `packages/`, `clusters/` or `environments/` |
| `exceptions-current` | An exception path matches no file |
| `hk-globs-current` | An `hk.pkl` glob names a path that does not exist, or a top-level folder that is neither a layout folder nor a dot-path such as `.mise` |

The names are the folder names under `clusters/` and `environments/`. A name counts only as a whole token: `sample` in `samples`, `edge-proxy`, `images/sample-app` or `cluster.sample` does not count. A `role:` line never counts, so a role value such as `workload` is vocabulary, not a name.

## Exceptions

Each exception lists the paths a rule skips and the build items that remove them. When the last covered file is deleted, the lint fails until the exception is removed too, so an exception cannot outlive its code.

## Renaming a cluster

`cluster_name_places` lists every place a cluster name appears. To rename cluster `<old>` to `<new>` in environment `<env>`:

1. Move `clusters/<old>/` to `clusters/<new>/` with `git mv`.
2. Change the name in `environments/<env>/environment.yaml`.
3. Move `environments/<env>/tenants/<old>.yaml` and `environments/<env>/deltas/<old>/`.
4. Recreate the machine as `<env>-<new>`. The machine name is its identity, so a rename is a rebuild.
5. Re-enroll the cluster. The mesh cluster name, the OpenBao mount `auth/k8s/<new>`, the object names `k8s-<new>-<component>`, the zot certificate CN `remote-<new>` and the repository prefix `tenants/<new>/` all follow from the tenant file.
6. Run `mise run check`. The name rules fail if `<old>` or `<new>` appears anywhere else.
