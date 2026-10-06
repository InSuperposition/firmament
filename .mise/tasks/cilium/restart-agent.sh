#!/usr/bin/env bash
#MISE description="Restart the Cilium agent on every node and wait for it to be ready again, so traffic started by cilium:traffic-start crosses an agent restart (restarts pods)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

claim_environment
kubeconfig=$(environment_kubeconfig)
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout restart daemonset/cilium
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout=10m
cilium --kubeconfig "$kubeconfig" status --wait --interactive=false
