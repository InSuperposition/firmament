#!/usr/bin/env bash
#MISE description="Plan a whole environment: its OrbStack machines, then k0s once the machines exist, then its Flux bootstrap once the environment records a cluster"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

plan_machines "$environment"
init_environment "$environment"
# The root installs k0s on the machines orb:apply recorded, so before they
# exist there is nothing to plan it against.
if [[ ! -f "$(state_directory "$environment")/machine-hosts.yaml" ]]; then
  printf 'No machines recorded yet, so k0s and the bootstrap are not planned; env:apply creates the machines first.\n'
  exit 0
fi
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
