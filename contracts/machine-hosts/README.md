# machine-hosts

Abstract: How to reach one machine: its name, addresses and SSH access.
`roots/machine-orb` writes `machine-hosts.yaml` into the environment's
state directory, and `roots/kubernetes-k0s` reads it. The schema
(`schema.cue`) is closed: a field not listed here is refused.
`mise run contracts:lint` checks the sample beside the schema, and
`roots/kubernetes-k0s` checks the file it reads against the same fields
at plan time, naming the field that fails.

| Field | Type | Rule |
| --- | --- | --- |
| `name` | string | `^[a-z][a-z0-9-]*$` |
| `dns_name` | string | not empty |
| `ip_address` | string | an IP address |
| `ssh.address` | string | not empty |
| `ssh.port` | integer | 1 to 65535 |
| `ssh.user` | string | not empty |
| `ssh.key_path` | string | not empty |
| `ssh.host_keys` | list of strings | at least one entry; each entry is a `known_hosts` key, `<type> <base64 key>`, with a type of `ssh-ed25519`, `ssh-rsa` or `ecdsa-sha2-nistp256`, `-nistp384` or `-nistp521` |

`roots/machine-orb` writes `ssh.host_keys` from OrbStack's own `known_hosts`;
an absent or empty list is refused, because k0sctl checks the server key
against it.

See also [cluster-access](../cluster-access/README.md) and
[environment](../environment/README.md); change a field name in all of
them together.
