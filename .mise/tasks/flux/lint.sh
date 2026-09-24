#!/usr/bin/env bash
#MISE description="Render every environment's Flux build with test runtime values and validate it against the Kubernetes and Flux schemas; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# Each environment's build is validated once, components included, with the
# schema catalog built into flux-schema, so no network is needed.
status=0
mapfile -t builds < <(find "$MISE_PROJECT_ROOT/environment" -mindepth 2 -maxdepth 2 -type d -name flux | sort)
for build in "${builds[@]}"; do
  if ! render_flux_build "$build" | flux-schema validate; then
    printf '%s: the rendered Flux build is not valid\n' "$build" >&2
    status=1
  fi
done
exit "$status"
