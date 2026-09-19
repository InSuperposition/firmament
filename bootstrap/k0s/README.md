# k0s bootstrap

Abstract: Render the declarative k0sctl contract with explicit host connection
values, then dry-run and apply one `controller+worker` node.

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

OrbStack's built-in SSH endpoint accepts the `root@firmament` user used by
k0sctl. This avoids a temporary-file ownership limitation when k0sctl stages
files through `sudo`. The Ubuntu readiness check can still use the ordinary
developer endpoint through `FIRMAMENT_SSH_TARGET`.

For another Ubuntu host, replace these values with its ordinary SSH endpoint
and API address. The k0s task never invokes OrbStack.

## Contract

`k0sctl.yaml` is the source of truth for the cluster: k0s version, single-node
role, custom CNI, kube-proxy replacement, Pod/Service CIDRs, and lifecycle
options. The renderer changes only connection fields and the API address in a
temporary copy under external target state.

k0s is pinned to `1.36.4+k0s.0`; k0sctl is pinned to `0.33.0`. The selected
candidate must pass dry-run and live apply on the prepared Ubuntu target before
it is treated as a verified compatibility pin.

The kubeconfig is written outside Git with mode `0600`. Rendered configuration,
kubeconfig, and run state live under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/k0s/
```

The target lock prevents concurrent renders or applies from sibling worktrees.

The first apply owns only k0s and its managed containerd. It does not install
Cilium, Flux, or workloads.
