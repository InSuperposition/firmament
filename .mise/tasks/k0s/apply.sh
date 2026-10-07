#!/usr/bin/env bash
#MISE description="Install k0s with the Kubernetes root and k0sctl, from a clean checkout at the tip of its branch on origin (render, k0sctl apply, kubeconfig, then the cluster-access contract), then wait for the node to register; Cilium and Flux come from env:apply"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

claim_environment
apply_kubernetes_root
kubeconfig=$(environment_kubeconfig)
wait_for_node "$kubeconfig"
