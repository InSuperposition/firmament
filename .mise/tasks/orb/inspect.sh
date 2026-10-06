#!/usr/bin/env bash
#MISE description="Print the OrbStack machine's native metadata without changing it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

machine=$(contract_field machine-hosts.yaml .name)
orb info "$machine" --format json
