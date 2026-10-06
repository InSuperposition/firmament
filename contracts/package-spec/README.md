# package-spec

Abstract: The `package.yaml` file format: what one package is, what it
requires and provides, and which delta keys it accepts. The schema
(`schema.cue`) is closed and has no `namespace` field, because a binding
places a package (see [bindings-spec](../bindings-spec/README.md)).
`mise run contracts:lint` checks the sample. The Timoni modules that read
the file check it again through a vendored copy of the schema.

| Field | Type | Rule |
| --- | --- | --- |
| `name` | string | `^[a-z][a-z0-9-]*$` |
| `layer` | string | same pattern; open until a third package shows the set of layers |
| `pin.source` | string | not empty |
| `pin.version` | string | not empty |
| `pin.digest` | string | `sha256:` and 64 hex characters |
| `bootstrap` | bool | optional; applied once from upstream |
| `delta_keys` | list of strings | optional; the keys an environment delta may set |
| `requires[]` | `capability`, `scope` | `scope` is `cluster` or `mesh` |
| `provides[]` | `capability`, `scope`, `port`, `protocol`, `readiness {kind, name}` | `port` 1 to 65535, `protocol` `TCP` or `UDP` |

Cross-file rules (every requirement met exactly once, no cycle, a delta key
declared here) belong to the modules and the `inputs` package that read
several files.

See also [cluster-spec](../cluster-spec/README.md),
[delta-spec](../delta-spec/README.md) and the
[environment](../environment/README.md) contract.
