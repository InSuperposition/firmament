# bootstrap-flux

Abstract: The bootstrap root. Reads the `cluster-access` contract the
Kubernetes root wrote and bootstraps Cilium, then Flux Operator and the
`FluxInstance`, once, into that cluster. From then on Flux reconciles all
three from `packages/cilium` and `packages/flux`.

## How it bootstraps

`bootstrap.tf` calls the upstream
[flux-operator-bootstrap](https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap)
module, pinned by commit. Its Job installs Cilium, then Flux Operator and
the `FluxInstance`. The bootstrap reads each chart digest, the values and
the `FluxInstance` from `packages/`, so both install the same bytes, under
the release names Flux adopts. Increment `bootstrap_revision` only to
rerun the Job on purpose.

The Job installs the pod network, so it runs before one exists: on the
host network, with the API address set directly, tolerating the node that
is not Ready yet. The `runtime_info` values from the contract become the
`flux-runtime-info` ConfigMap, labelled so a change (such as a new branch
to follow) reaches the root Kustomization at once.

This is its own root, applied after the Kubernetes root: the Kubernetes
provider docs warn against configuring the provider from resources created
in the same apply. `env:destroy` and `orb:destroy` leave it alone: its
objects live in the cluster and go with the machine, and the next apply's
refresh finds them gone and plans them again.

## Inputs

| Input | Source |
| --- | --- |
| `state_directory` | the mise tasks (`TF_VAR_state_directory`) |
| `cluster-access.yaml` | the Kubernetes root, in the state directory |

State: `$FIRMAMENT_STATE_HOME/environments/<env>/bootstrap-flux.tfstate`.

## Tests

`tests/integration.bats` plans this root against the `cluster-access`
contract the Kubernetes root plans, so it also checks the two roots agree.
