#!/usr/bin/env bash
#MISE description="Check every environment's inventory against its closed schema: an unknown tenant or package, a namespace with two tenants and a chart without a digest are refused; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

cd "$MISE_PROJECT_ROOT"
cue vet -c render/inventory.cue
