#!/usr/bin/env bash
#MISE description="Restart the Cilium agent on every node and wait for it to be ready again, so traffic started by cilium:traffic-start crosses an agent restart (restarts pods)"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

claim_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout restart daemonset/cilium
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout=10m
cilium --kubeconfig "$kubeconfig" status --wait --interactive=false
