#!/usr/bin/env bash
#MISE description="Apply a whole environment, then wait for Flux and Cilium to be ready and the node to be Ready"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" apply -input=false -auto-approve
wait_for_cluster "$environment"
