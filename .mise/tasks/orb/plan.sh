#!/usr/bin/env bash
#MISE description="Plan the machine root: the OrbStack machine and its readiness check"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" machine-orb
tofu_in_root "$environment" machine-orb plan -input=false
