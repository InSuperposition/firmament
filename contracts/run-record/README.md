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
