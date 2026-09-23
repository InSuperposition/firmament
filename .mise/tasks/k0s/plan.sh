#!/usr/bin/env bash
#MISE description="Plan the k0s cluster, its Helm charts and kubeconfig (pulls in the machine and readiness check if they don't exist yet)"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" plan -input=false -target=module.orch_k0s -target=local_sensitive_file.kubeconfig
