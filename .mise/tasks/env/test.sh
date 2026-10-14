#!/usr/bin/env bash
#MISE description="Test each root's wiring and the contracts between roots against plans in a temporary state, without touching infrastructure"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

mapfile -t suites < <(find "${MISE_PROJECT_ROOT:?run this through mise}/tofu/roots" -path '*/tests/*.bats' | sort)
if ((${#suites[@]} == 0)); then
  fail "no root suite (tests/*.bats) under tofu/roots; a moved folder would otherwise pass with no test run" || exit
fi
bats "${suites[@]}"
