# cluster-spec

Abstract: The `clusters/<name>/cluster.yaml` file format. A cluster has no
`role`: its roles are what its packages provide. The schema (`schema.cue`)
is closed, so each later fact needs a schema edit. `mise run contracts:lint`
checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `name` | string | `^[a-z][a-z0-9-]*$`; the name of the folder `clusters/<name>/` |

See also [bindings-spec](../bindings-spec/README.md), which holds the
cluster's `packages.yaml`.
