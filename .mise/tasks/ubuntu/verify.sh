#!/usr/bin/env bash
#MISE description="Check Ubuntu readiness on the machine by planning the machine root, whose os-ubuntu module runs its probe over SSH"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root machine-orb
tofu_in_root machine-orb plan -input=false
