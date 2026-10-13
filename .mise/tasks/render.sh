#!/usr/bin/env bash
#MISE description="Check the data files and render each declared environment's namespaces into clusters/<cluster>/rendered/<environment>; CI runs it before the artifact is pushed"
set -euo pipefail
cd "${MISE_PROJECT_ROOT:?}"

cue vet -c .:inputs

# Build every environment first, so a failed build leaves the last complete
# render in place.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

while IFS=$'\t' read -r cluster environment; do
  ENVIRONMENT="$environment" timoni bundle build -f render/bundle.cue --runtime-from-env \
    --output-dir "$staging/$cluster/$environment"
done < <(cue export .:inputs -e environments --out json |
  jq -r 'to_entries | sort_by(.key)[] | [.value.cluster, .key] | @tsv')

# Replace every generated tree, so a removed environment leaves nothing behind.
rm -rf clusters/*/rendered
for built in "$staging"/*/; do
  cluster="$(basename "$built")"
  mkdir -p "clusters/$cluster"
  mv "$built" "clusters/$cluster/rendered"
done
