#!/usr/bin/env bash
#MISE description="Plan the machine root: the OrbStack machine and its readiness check"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root machine-orb
tofu_in_root machine-orb plan -input=false
