#!/usr/bin/env bash
#MISE description="Show which OrbStack machines orb:apply would create, keep, or refuse because their limits differ; changes nothing"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

plan_machines "$environment"
