#!/usr/bin/env bash
#MISE description="Render every environment's Flux build with test runtime values and validate it against the vendored Kubernetes and Flux schemas, offline; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# Each environment's build is validated once, components included, against
# the schemas vendored in .mise/flux-schemas (flux:schemas refreshes them),
# so the result depends only on this commit and needs no network.
status=0
mapfile -t builds < <(find "$MISE_PROJECT_ROOT/environment" -mindepth 2 -maxdepth 2 -type d -name flux | sort)
if ((${#builds[@]} == 0)); then
  fail "no environment/*/flux build to validate under $MISE_PROJECT_ROOT/environment"
  exit 1
fi
for build in "${builds[@]}"; do
  if ! render_flux_build "$build" | flux-schema validate --schema-location "$MISE_PROJECT_ROOT/.mise/flux-schemas"; then
    printf '%s: the rendered Flux build is not valid; for a kind with no schema yet, run mise run flux:schemas\n' "$build" >&2
    status=1
  fi
done
exit "$status"
