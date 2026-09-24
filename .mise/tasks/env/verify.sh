#!/usr/bin/env bash
#MISE description="Run the environment's read-only chainsaw suite (tests/cluster) against its cluster"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

suite="$(environment_directory "$environment")/tests/cluster"
if [[ ! -d "$suite" ]]; then
  fail "environment '$environment' has no cluster suite at $suite"
fi

init_environment "$environment"
chainsaw_in_environment "$environment" test --test-dir "$suite"
