#!/usr/bin/env bash
#MISE description="Refresh the schemas flux:lint validates against: one per kind the Flux builds render, from flux-schema's catalog at a pinned commit"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# The commit tag v0.13.0 of flux-schema points at. mise.toml pins the same
# flux-schema version for the CLI; update both together.
catalog="https://raw.githubusercontent.com/fluxcd/flux-schema/88c74c0294aaf472a8df920f92a2f28811a47d72/catalog/latest"
schemas="$MISE_PROJECT_ROOT/.mise/flux-schemas"

# Prints "<group>/<kind>_<version>.json" for each kind the builds render,
# once. Core Kubernetes kinds, with no API group, live under core/.
schema_paths() {
  local build
  for build in "$MISE_PROJECT_ROOT"/environment/*/flux; do
    render_flux_build "$build" |
      yq -N -r 'select(.kind) | .apiVersion + " " + .kind'
  done | sort -u | while read -r api_version kind; do
    kind=$(tr '[:upper:]' '[:lower:]' <<<"$kind")
    if [[ "$api_version" == */* ]]; then
      printf '%s/%s_%s.json\n' "${api_version%/*}" "$kind" "${api_version#*/}"
    else
      printf 'core/%s_%s.json\n' "$kind" "$api_version"
    fi
  done
}

listing=$(schema_paths)
[[ -n "$listing" ]] || fail "no environment/*/flux build renders any kind" || exit 1
mapfile -t paths <<<"$listing"

# Downloads into a staging directory and replaces the vendored schemas only
# once every download succeeded.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
for path in "${paths[@]}"; do
  mkdir -p "$staging/$(dirname -- "$path")"
  curl -fsSL "$catalog/$path" -o "$staging/$path"
  printf '%s\n' "$path"
done
rm -rf "$schemas"
mv "$staging" "$schemas"
