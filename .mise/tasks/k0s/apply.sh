#!/usr/bin/env bash
#MISE description="Apply only the k0s cluster and its kubeconfig, then wait for the node to register; Cilium and Flux come from env:apply"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" apply -input=false -auto-approve -target=module.orch_k0s -target=local_sensitive_file.kubeconfig
wait_for_node "$(environment_kubeconfig "$environment")"
