# run-record

Abstract: What one run of the tour observed, as plain data. The tour writes a
record while it runs and the evidence task reads it. Each action keeps its
time, command, exit status, the reference it tested, the controls that made
the check meaningful, and what the cluster answered. The schema (`schema.cue`)
is closed. `mise run contracts:lint` checks the sample; the tasks that write
or read a record check it against the same fields.

| Field | Type | Rule |
| --- | --- | --- |
| `schema` | integer | `1` |
| `started`, `finished` | string | UTC time, `YYYY-MM-DDTHH:MM:SSZ`; `finished` is required when the record is complete |
| `revision.checkout` | string | the 40-character commit the checkout is at |
| `revision.cluster` | string | the 40-character commit the cluster runs |
| `revision.matches` | boolean | whether the two are equal |
| `complete` | boolean | `true` only when every action ran, exited with `0` and passed every control |
| `actions[]` | list | a complete record holds exactly three, in this order: `wrong-signer-chart-refused`, `direct-access-denied-gateway-allowed`, `unsigned-image-refused` |

An action holds `guarantee`, `started`, `finished`, `command`, `exit_status`,
an optional `reference` (`kind` is `tag` or `digest`, so a tag is never
mistaken for a digest), at least one control (`name`, `passed`) and at least
one observation. A selector prints the same object, without `started` and
`finished`, as the last line of its output.

Each guarantee has a task that runs only it and prints that object:

| Guarantee | Task | What it keeps |
| --- | --- | --- |
| `wrong-signer-chart-refused` | `mise run tenant:verify --only wrong-signer-chart-refused [--hold]` | the cv chart source with the real signer verifies, and a copy that demands another signer is refused for its identity; `--hold` keeps the refused source until Enter, so the Flux UI can show it |
| `direct-access-denied-gateway-allowed` | `mise run network-policy:verify --only direct-access-denied-gateway-allowed` | a pod in `default` is dropped on the way to the cv pod, and the Gateway still serves cv to it (the result of `gateway:verify --result`) |
| `unsigned-image-refused` | `mise run kyverno:verify --only unsigned-image-refused` | the signed cv image is admitted, an unsigned image is refused in `cv` and admitted in `default` |

When a selector fails it still prints the object, with its exit status and the
control in progress marked as not passed, so the caller can keep the failed
action in an incomplete record. The reference of the unsigned-image action is a
tag; that of the chart action is a digest.

An observation is one of:

- `refusal` or `condition` with a `line`;
- `flow` with a Hubble `verdict` (`FORWARDED` or `DROPPED`), a `count` and the
  `window_seconds` it was read over;
- `http` with a `status`.

A `line` is kept only when it carries one of the known refusal phrases and
names no address and no pod: no dotted IPv4 address, no IPv6 group, and no name
of three or more dash-separated parts. Any other line is stored as
`[line withheld: names an address or a pod]`. The rule is in the schema, so
the tour, the evidence task and `contracts:lint` apply the same one.

An incomplete record (`complete: false`) holds what ran before a failure. It
is kept for the log and is never published.

See also [cluster-access](../cluster-access/README.md).
