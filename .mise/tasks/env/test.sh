#!/usr/bin/env bash
#MISE description="Test each root's wiring and the contracts between roots against plans in a temporary state, without touching infrastructure"
set -euo pipefail

mapfile -t suites < <(find "${MISE_PROJECT_ROOT:?run this through mise}/roots" -path '*/tests/*.bats' | sort)
bats "${suites[@]}"
