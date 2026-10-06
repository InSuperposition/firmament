#!/usr/bin/env bash
#MISE description="Wait for the Cilium release to run the values Flux applied, then for the agent, operator, Hubble Relay and Hubble UI to be ready"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

kubeconfig=$(environment_kubeconfig)
wait_for_cilium_values "$kubeconfig"
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout=10m
cilium --kubeconfig "$kubeconfig" status --wait --interactive=false
