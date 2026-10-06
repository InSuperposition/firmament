#!/usr/bin/env bash
#MISE description="Apply the machine, Kubernetes and bootstrap roots in order, then wait for Flux and Cilium to be ready and the node to be Ready"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root machine-orb
claim_environment
refuse_k0s_charts
# Each root reads the contract file the one before it wrote, so they apply
# in order: the machine, then k0s on it, then the bootstrap into the cluster.
tofu_in_root machine-orb apply -input=false -auto-approve
apply_kubernetes_root
init_root bootstrap-flux
tofu_in_root bootstrap-flux apply -input=false -auto-approve
wait_for_cluster
