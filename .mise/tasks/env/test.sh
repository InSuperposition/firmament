#!/usr/bin/env bash
#MISE description="Test an environment's module wiring against a plan in a temporary state, without touching infrastructure"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

directory=$(environment_directory "$environment")
bats "$directory/tests/integration.bats"
