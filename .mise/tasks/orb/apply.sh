#!/usr/bin/env bash
#MISE description="Apply the machine root: create the OrbStack machine, check Ubuntu readiness, write the machine-hosts contract, then print the machine's native metadata"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" machine-orb
claim_environment "$environment"
tofu_in_root "$environment" machine-orb apply -input=false -auto-approve
machine=$(contract_field "$environment" machine-hosts.yaml .name)
orb info "$machine" --format json
