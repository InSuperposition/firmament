#!/usr/bin/env bash
#MISE description="Create the OrbStack machine only, then print its native metadata"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
claim_environment "$environment"
tofu_in_environment "$environment" apply -input=false -auto-approve -target=module.vm_orb
orb info "$(environment_output "$environment" machine_name)" --format json
