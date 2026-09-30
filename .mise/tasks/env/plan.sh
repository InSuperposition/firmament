#!/usr/bin/env bash
#MISE description="Plan a whole environment, then its Flux bootstrap once the environment records a cluster"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" plan -input=false

# The bootstrap plans against the cluster in the environment's state, so a
# fresh environment has nothing to plan it against yet.
kubeconfig=$(environment_output_or_empty "$environment" kubeconfig_path)
if [[ -z "$kubeconfig" ]]; then
  printf 'No cluster recorded yet, so the bootstrap is not planned; it is applied after the cluster.\n'
  exit 0
fi
init_bootstrap "$environment"
tofu_in_bootstrap "$environment" plan -input=false
