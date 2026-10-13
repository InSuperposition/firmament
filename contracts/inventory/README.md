# inventory

Abstract: The inventory of one environment: for each bound namespace, its
tenant, quota and administrators, and the packages in it with each chart's
source, version, digest and whether Flux verifies its signature. It is
derived from `environments/<env>/tenants/`, `clusters/<name>/packages.yaml`
and `packages/*/package.yaml` by `render/inventory.cue`, so nothing reads it
as input and nothing edits it. `mise run inventory:generate` writes it to
`inventory.json` in the environment's state directory; `mise run
inventory:lint` refuses data that does not match the closed schema
(`schema.cue`). `mise run contracts:lint` checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `environment` | string | `^[a-z][a-z0-9-]*$` |
| `namespaces.<name>` | object | one entry per bound namespace |
| `tenant` | string | the tenant the bindings give the namespace |
| `kind` | string | `platform`, `team` or `customer` |
| `administrators` | list of strings | from the tenant; may be empty |
| `quota.cpu`, `quota.memory` | string | Kubernetes quantities, from the tenant |
| `packages` | list | not empty; one item per binding in the namespace |
| `packages[].name`, `layer` | string | from `package.yaml` |
| `packages[].source`, `version`, `digest` | string | the chart pin; the digest is `sha256:` and 64 hex digits |
| `packages[].bootstrap` | bool | the bootstrap installs it |
| `packages[].signed` | bool | `package.yaml` has a `verify` block |
| `packages[].hostPorts`, `ingressPorts` | list | the ports `package.yaml` lists; may be empty |

See also [tenant-spec](../tenant-spec/README.md),
[bindings-spec](../bindings-spec/README.md) and
[package-spec](../package-spec/README.md).
