#!/usr/bin/env bash
#MISE description="Apply the Kubernetes root (k0s, its kubeconfig and the cluster-access contract), then wait for the node to register; Cilium and Flux come from env:apply"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root kubernetes-k0s
claim_environment
tofu_in_root kubernetes-k0s apply -input=false -auto-approve
kubeconfig=$(environment_kubeconfig)
wait_for_node "$kubeconfig"
