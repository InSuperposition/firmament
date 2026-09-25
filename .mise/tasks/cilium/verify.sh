#!/usr/bin/env bash
#MISE description="Wait for the Cilium release to run the values Flux applied, then for the agent, operator, Hubble Relay and Hubble UI to be ready"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
wait_for_cilium_values "$kubeconfig"
kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout=10m
cilium --kubeconfig "$kubeconfig" status --wait --interactive=false
