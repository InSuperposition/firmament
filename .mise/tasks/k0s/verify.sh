#!/usr/bin/env bash
#MISE description="Wait for every node in the cluster to be Ready"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
