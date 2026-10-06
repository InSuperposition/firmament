# delta-spec

Abstract: The `environments/<env>/deltas/<cluster>/<package>.yaml` file
format: a sparse divergence from the cluster's values for one package in one
environment, with the reason for it. The schema (`schema.cue`) is closed.
`mise run contracts:lint` checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `reason` | string | not empty |
| `values` | map | keys not empty; each key must be one the package lists in `delta_keys` |

The `delta_keys` rule spans two files, so the module that consumes the delta
checks it.

See also [package-spec](../package-spec/README.md).
