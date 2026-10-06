#!/usr/bin/env bash
#MISE description="Apply the machine root: create the OrbStack machine, check Ubuntu readiness, write the machine-hosts contract, then print the machine's native metadata"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root machine-orb
claim_environment
tofu_in_root machine-orb apply -input=false -auto-approve
machine=$(contract_field machine-hosts.yaml .name)
orb info "$machine" --format json
