#!/usr/bin/env bash
#MISE description="Destroy a whole environment"
#MISE confirm="Destroy environment {{usage.environment}} and everything in it?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" destroy -input=false -auto-approve
