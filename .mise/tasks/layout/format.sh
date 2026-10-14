#!/usr/bin/env bash
#MISE description="Write the README block between its markers from contracts/layout/layout.yaml and the tracked tree; changes nothing else"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-layout.sh
source "$MISE_PROJECT_ROOT/.mise/lib-layout.sh"
cd "$MISE_PROJECT_ROOT"

problem=$(layout_marker_problem "$layout_readme")
if [[ -n "$problem" ]]; then
  fail "layout:format wrote nothing: $problem" || exit
fi
block=$(mktemp "${TMPDIR:-/tmp}/layout-block.XXXXXX")
trap 'rm -f -- "$block"' EXIT
layout_render_block >"$block"
if [[ "$(layout_current_block "$layout_readme")" == "$(cat -- "$block")" ]]; then
  exit 0
fi
layout_replace_block "$layout_readme" "$block"
printf 'updated the block in %s\n' "$layout_readme"
