#!/usr/bin/env bash
#MISE description="Print the OrbStack machine's native metadata without changing it"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
orb info "$(environment_output "$environment" machine_name)" --format json
