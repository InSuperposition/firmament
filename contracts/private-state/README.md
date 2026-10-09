# private-state

Abstract: The manifest of the secret files a build keeps outside Git and
OpenTofu state, in `$FIRMAMENT_STATE_HOME/environments/<env>/openbao/`
(C81). `mise run openbao:seed` writes `private-state.yaml` there when it
first generates the files, and reads it on every later run. The manifest holds
no secret: it names each file, beside it, with the mode it must have. The
schema (`schema.cue`) is closed. `mise run contracts:lint` checks the sample.

| Field | Type | Rule |
| --- | --- | --- |
| `openbao.seal_key` | `path`, `mode` | the static seal key, 32 random bytes in a binary file; mode `0600` |
| `openbao.operator_ca.certificate` | `path`, `mode` | the CA whose certificates may log in as operator; mode `0600` or `0644` |
| `openbao.operator_ca.key` | `path`, `mode` | its key; mode `0600` |
| `openbao.operator_client.certificate` | `path`, `mode` | one client certificate signed by that CA |
| `openbao.operator_client.key` | `path`, `mode` | its key; mode `0600` |
| `openbao.snapshot` | `path`, `mode`, `root_fingerprint` | optional: the newest Raft snapshot and the SHA-256 (lowercase hex) of the root it holds; mode `0600` |
| `openbao.snapshot_previous` | same | optional: the snapshot before it, kept by the next save |

`path` is a file name beside the manifest, with no directory part.

A manifest that exists while a file it names is missing means the private
state was damaged, not that it is new: the seed task stops and names the file
instead of generating a new seal key, because a new key cannot unseal the data
the old one protected.

Lost private state is lost for good: it lives on one machine and nothing here
backs it up (C39).

See also [package-spec](../package-spec/README.md).
