# tenant-spec

Abstract: The `environments/<env>/tenants/<name>.yaml` file format: an
owner of namespaces that bindings refer to by name. The schema
(`schema.cue`) is closed. The kind `cluster` is reserved for a later
enrolled cluster and is refused until then. `mise run contracts:lint`
checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `kind` | string | `platform`, `team` or `customer` |
| `quota.cpu` | string | a Kubernetes quantity, such as `4` or `500m` |
| `quota.memory` | string | a Kubernetes quantity, such as `8Gi` |
| `administrators` | list of strings | each not empty; may be empty |

See also [bindings-spec](../bindings-spec/README.md).
