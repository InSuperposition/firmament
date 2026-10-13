# bindings-spec

Abstract: The `clusters/<name>/packages.yaml` file format: a list of
bindings, each placing one package in a namespace for a tenant. A tenant is
a label on a binding, so one cluster definition serves different tenants in
different environments. The schema (`schema.cue`) is closed, so a binding
without a tenant is refused. `mise run contracts:lint` checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `package` | string | `^[a-z][a-z0-9-]*$`; names `packages/<package>/` |
| `namespace` | string | same pattern |
| `tenant` | string | same pattern; must name a tenant the environment defines |
| `retired` | `true`, optional | absent means active; a retired binding keeps its namespace, quota and network policy but renders no chart source, values or HelmRelease; a bootstrap package cannot be retired |

Pruning is off on the chart objects, so retiring a binding does not uninstall
the chart. `mise run bindings:verify` lists what a retirement left behind and
fails until an explicit teardown removes it. A retired binding stays in the
file after the teardown.

Whether the package and the tenant exist spans several files, so the
`namespace` and `cilium-policy` modules check it when they render.

See also [package-spec](../package-spec/README.md) and
[tenant-spec](../tenant-spec/README.md).
