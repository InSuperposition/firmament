# machine-orb

Abstract: The machine root. Creates the OrbStack machine with
`modules/vm-orb`, checks it with the Ubuntu readiness postconditions of
`modules/os-ubuntu`, and writes the `machine-hosts` contract the
Kubernetes root reads. It is the only root that knows the machine runs on
OrbStack.

## Composition

```hcl
module "vm_orb"    { source = "../../modules/vm-orb" }
module "os_ubuntu" { source = "../../modules/os-ubuntu"; ssh_target = module.vm_orb.ssh_target }
resource "local_file" "machine_hosts" { ...; depends_on = [module.os_ubuntu] }
```

## Contract out: `machine-hosts.yaml`

Written into the environment's state directory only after the readiness
postconditions pass, so the Kubernetes root never starts on a host that
failed them. Destroying this root deletes the file, so a missing file
means no machine.

```yaml
name: firmament
dns_name: firmament.orb.local
ip_address: 192.168.139.10
ssh:
  address: 127.0.0.1   # OrbStack's SSH proxy
  port: 32222
  user: root@firmament
  key_path: ~/.orbstack/ssh/id_ed25519
```

k0sctl reaches the machine with the SSH key OrbStack creates. To use
another key, set `TF_VAR_orbstack_ssh_key_path` to its absolute path.

## Inputs

| Variable | Set by |
| --- | --- |
| `state_directory` | the mise tasks (`TF_VAR_state_directory`) |
| `orbstack_ssh_key_path` | optional; defaults to OrbStack's key |

State: `$FIRMAMENT_STATE_HOME/environment/<env>/machine-orb.tfstate`.

## Tests

`tests/integration.bats` plans this root offline: the default and the
caller-set SSH key, and where the contract is written.
