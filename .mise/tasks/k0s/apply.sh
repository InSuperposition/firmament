#!/usr/bin/env bash
#MISE description="Apply the Kubernetes root (k0s, its kubeconfig and the cluster-access contract), then wait for the node to register; Cilium and Flux come from env:apply"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" kubernetes-k0s
claim_environment "$environment"
tofu_in_root "$environment" kubernetes-k0s apply -input=false -auto-approve
kubeconfig=$(environment_kubeconfig "$environment")
wait_for_node "$kubeconfig"
