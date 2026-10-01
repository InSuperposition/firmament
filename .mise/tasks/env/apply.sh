#!/usr/bin/env bash
#MISE description="Apply the machine, Kubernetes and bootstrap roots in order, then wait for Flux and Cilium to be ready and the node to be Ready"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" machine-orb
claim_environment "$environment"
refuse_k0s_charts "$environment"
# Each root reads the contract file the one before it wrote, so they apply
# in order: the machine, then k0s on it, then the bootstrap into the cluster.
tofu_in_root "$environment" machine-orb apply -input=false -auto-approve
init_root "$environment" kubernetes-k0s
tofu_in_root "$environment" kubernetes-k0s apply -input=false -auto-approve
init_root "$environment" bootstrap-flux
tofu_in_root "$environment" bootstrap-flux apply -input=false -auto-approve
wait_for_cluster "$environment"
