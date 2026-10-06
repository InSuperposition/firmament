# machine-orb

Abstract: The machine root. Reads `environments/<env>/environment.yaml`,
creates the OrbStack machine, named `<environment>-<cluster>`, with
`modules/vm-orb`, checks it with the Ubuntu readiness postconditions of
`modules/os-ubuntu`, and writes the `machine-hosts` contract the
Kubernetes root reads. It is the only root that knows the machine runs on
OrbStack.

## Composition

```hcl
module "vm_orb"    { source = "../../modules/vm-orb"; name = "<environment>-<cluster>" }
module "os_ubuntu" { source = "../../modules/os-ubuntu"; ssh_target = module.vm_orb.ssh_target }
resource "local_file" "machine_hosts" { ...; depends_on = [module.os_ubuntu] }
```

## Contract out: `machine-hosts.yaml`

Written into the environment's state directory only after the readiness
postconditions pass, so the Kubernetes root never starts on a host that
failed them. Destroying this root deletes the file, so a missing file
means no machine.

```yaml
name: local-singularity
dns_name: local-singularity.orb.local
ip_address: 192.168.139.10
ssh:
  address: 127.0.0.1   # OrbStack's SSH proxy
  port: 32222
  user: root@local-singularity
  key_path: ~/.orbstack/ssh/id_ed25519
  host_keys:
    - ssh-ed25519 AAAA...
    - ecdsa-sha2-nistp256 AAAA...
```

k0sctl reaches the machine with the SSH key OrbStack creates and checks the
server key against `host_keys`, which `modules/vm-orb` reads from OrbStack's
own `known_hosts`. To use another key, replace or symlink OrbStack's key
file; this root takes no key setting.

## Inputs

| Variable | Set by |
| --- | --- |
| `state_directory` | the mise tasks (`TF_VAR_state_directory`) |
| `environment` | the mise tasks (`TF_VAR_environment`) |
| `environments_directory` | optional; the repository's `environments` folder when unset |

State: `$FIRMAMENT_STATE_HOME/environments/<env>/machine-orb.tfstate`.

## Tests

`tests/integration.bats` plans this root offline, with `HOME` set to a
fixture directory holding OrbStack's `known_hosts`: the machine name, a
cluster the environment does not allocate, and where the contract is
written.
