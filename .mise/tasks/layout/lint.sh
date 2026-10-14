#!/usr/bin/env bash
#MISE description="Check that contracts/layout/layout.yaml matches the tracked top-level folders, that every package has a kind and a README, that the find paths exist and that the README block is the render of the layout; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-layout.sh
source "$MISE_PROJECT_ROOT/.mise/lib-layout.sh"
cd "$MISE_PROJECT_ROOT"

problems=$(layout_problems)
if [[ -n "$problems" ]]; then
  printf '%s\n' "$problems" >&2
  fail "layout: the repository map disagrees with the tree or the README" || exit
fi
