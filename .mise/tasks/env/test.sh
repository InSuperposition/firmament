#!/usr/bin/env bash
#MISE description="Test each root's wiring and the contracts between roots against plans in a temporary state, without touching infrastructure"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

environment_directory "$environment" >/dev/null
mapfile -t suites < <(find "$MISE_PROJECT_ROOT/roots" -path '*/tests/*.bats' | sort)
bats "${suites[@]}"
