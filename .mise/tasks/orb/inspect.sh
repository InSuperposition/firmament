#!/usr/bin/env bash
#MISE description="Print the OrbStack machine's native metadata without changing it"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

machine=$(contract_field "$environment" machine-hosts.yaml .name)
orb info "$machine" --format json
