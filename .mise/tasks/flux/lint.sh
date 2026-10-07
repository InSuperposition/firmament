#!/usr/bin/env bash
#MISE description="Render every environment's Flux build with test runtime values and validate it against the vendored Kubernetes and Flux schemas, offline; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# Each cluster's Flux build and payload are validated once, packages included, against
# the schemas vendored in .mise/flux-schemas (flux:schemas refreshes them),
# so the result depends only on this commit and needs no network.
status=0
mapfile -t builds < <(find "$MISE_PROJECT_ROOT/clusters" -mindepth 2 -maxdepth 2 -type d \( -name flux -o -name payload \) | sort)
if ((${#builds[@]} == 0)); then
  fail "no clusters/*/flux build to validate under $MISE_PROJECT_ROOT/clusters"
  exit 1
fi
for build in "${builds[@]}"; do
  if ! render_flux_build "$build" | flux-schema validate --schema-location "$MISE_PROJECT_ROOT/.mise/flux-schemas"; then
    printf '%s: the rendered Flux build is not valid; for a kind with no schema yet, run mise run flux:schemas\n' "$build" >&2
    status=1
  fi
done
exit "$status"
