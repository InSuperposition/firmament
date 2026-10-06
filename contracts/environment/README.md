# environment

Abstract: The facts an environment states about itself, in
`environments/<env>/environment.yaml`. `roots/kubernetes-k0s` and the mise
tasks read it. The schema (`schema.cue`) is closed, so each later fact needs
a schema edit. `mise run contracts:lint` checks the sample beside it, and
`roots/kubernetes-k0s` checks the file it reads against the same fields at
plan time, naming the field that fails.

| Field | Type | Rule |
| --- | --- | --- |
| `cluster` | string | `^[a-z][a-z0-9-]*$`; names `clusters/<cluster>/` |

See also [machine-hosts](../machine-hosts/README.md) and
[cluster-access](../cluster-access/README.md); change a field name in all
of them together.
