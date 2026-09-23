# k0s bootstrap

Abstract: Declare and apply one `controller+worker` k0s node through
OpenTofu, using the `Mirantis/k0sctl` provider's `k0sctl_config` resource.

## Run

Set the connection values for the selected Ubuntu host:

```sh
export FIRMAMENT_K0S_SSH_ADDRESS=127.0.0.1
export FIRMAMENT_K0S_SSH_USER='root@firmament'
export FIRMAMENT_K0S_SSH_PORT=32222
export FIRMAMENT_K0S_SSH_KEY="$HOME/.orbstack/ssh/id_ed25519"
export FIRMAMENT_K0S_API_ADDRESS=firmament.orb.local
mise run bootstrap:k0s
```

`mise run k0s:dry-run` plans the `k0sctl_config` resource without applying
it. `mise run k0s:apply` applies it and prints the resulting nodes.

OrbStack's built-in SSH endpoint accepts the `root@firmament` user used by
the provider. This avoids a temporary-file ownership limitation when the
underlying k0sctl engine stages files through `sudo`. The Ubuntu readiness
check can still use the ordinary developer endpoint through
`FIRMAMENT_SSH_TARGET`.

For another Ubuntu host, replace these values with its ordinary SSH endpoint
and API address. The k0s stage never invokes OrbStack.

## Reading the cluster

`mise.toml` exports `KUBECONFIG` pointing at this stage's rendered
kubeconfig, so a bare `kubectl get nodes` works from the repo directory —
no `--kubeconfig` flag needed — once your shell has it. See the root
[README](../../README.md#setup) for `eval "$(mise env)"` /
`mise activate`; `mise exec -- kubectl ...` also works without either.

**k0s runs on the guest, not on your machine** — that's the whole point of
this stage. The `k0s` binary k0sctl installs there is `-rwxr-x---`,
`root:root`: it's the `k0scontroller` systemd service's binary, not a
general-purpose CLI for the `tensor` user. If you SSH into the host
directly, `k0s ...` bare fails with `Permission denied`; use
`sudo k0s kubectl get nodes` (passwordless sudo is already required by
`bootstrap:ubuntu`'s readiness contract, so this doesn't prompt). Neither
`kubectl` nor `k0sctl` is installed on the guest — both are operator
tools that run from your machine against the guest's exposed API.

## Contract

`bootstrap/k0s/*.tf` is the source of truth for the cluster: k0s version,
single-node role, custom CNI, kube-proxy replacement, Pod/Service CIDRs,
and connection values built from `TF_VAR_*` environment variables that the
`k0s:*` mise tasks set from the `FIRMAMENT_K0S_*` inputs above. There is no
separate render step — `mise run k0s:dry-run` (`tofu plan`) is the
preview; the rendered `k0sctl.yaml` equivalent is only known after `apply`
(exposed as the `k0s_yaml` output) since the provider builds it internally
during `Create`, not during `Plan`.

k0s is pinned to `1.36.4+k0s.0` in `bootstrap/k0s/cluster.tf`. The
provider is pinned to `Mirantis/k0sctl` `0.0.3` in `bootstrap/k0s/main.tf`
— the newest version actually published to the Terraform Registry (the
GitHub repo's `v0.0.4` tag exists but was never released there). The
selected candidate must pass dry-run and live apply on the prepared
Ubuntu target before it is treated as a verified compatibility pin.

The kubeconfig is written outside Git with mode `0600`. OpenTofu's local
state, the rendered kubeconfig, and the provider plugin cache live under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/k0s/
```

OpenTofu's local backend holds a state lock during `plan`/`apply`,
preventing concurrent runs from sibling worktrees from corrupting state.

The first apply owns only k0s and its managed containerd. It does not
install Cilium, Flux, or workloads.

## State and the orb stage

This stage's state is independent of `bootstrap/orb`'s. If the OrbStack
machine gets deleted and recreated (`orb:delete` + `orb:create`), it comes
back reachable at the same SSH address/port but with nothing installed —
`k0sctl_config`'s refresh does not detect this, so `plan`/`apply` report
"No changes" against a host that no longer has k0s running. Recovery:
remove this stage's state file and reapply:

```sh
state="${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/k0s"
rm -f "$state/terraform.tfstate" "$state/terraform.tfstate.backup"
mise run bootstrap:k0s
```
