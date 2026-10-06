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
| `target` | string | `orbstack` |
| `engine` | string | `flux` |
| `artifact_source` | string | a lowercase `ghcr.io/<owner>/<repository>` |
| `clusters` | map | one allocation per cluster, and one for `cluster`; a name maps to `mesh_id` (integer from 1), `pod_cidr` (a CIDR) and optional `retired: true` |
| `credentials` | list of strings | optional; names only, the values live in private state |

Mesh ids and pod CIDRs are append-only: a removed cluster stays as
`retired: true`. A later OpenTofu rule checks that they are unique, do not
overlap and stay outside the service CIDR `10.96.0.0/12`, against recorded
state.
`roots/kubernetes-k0s` checks the fields above except the allocations.

Tenants and deltas are separate files: [tenant-spec](../tenant-spec/README.md)
and [delta-spec](../delta-spec/README.md).

See also [machine-hosts](../machine-hosts/README.md) and
[cluster-access](../cluster-access/README.md); change a field name in all
of them together.
