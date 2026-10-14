#!/usr/bin/env bash
#MISE description="Check the data files and render each declared environment into clusters/<cluster>/rendered/<environment> (namespaces and chart releases) and clusters/<cluster>/admission/<environment> (admission policies); CI runs it before the artifact is pushed"
set -euo pipefail
cd "${MISE_PROJECT_ROOT:?}"

cue vet -c .:inputs

# The bundle files and the folder each fills.
mapfile -t trees < <(yq -r '.trees[] | .bundle + " " + .folder' .mise/render-trees.yaml)
readonly trees

# Build every environment first, so a failed build leaves the last complete
# render in place.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

for tree in "${trees[@]}"; do
  read -r bundle folder <<<"$tree"
  while IFS=$'\t' read -r cluster environment; do
    ENVIRONMENT="$environment" timoni bundle build -f "timoni/bundles/$bundle" --runtime-from-env \
      --output-dir "$staging/$folder/$cluster/$environment"
  done < <(cue export .:inputs -e environments --out json |
    jq -r 'to_entries | sort_by(.key)[] | [.value.cluster, .key] | @tsv')
done

# Replace every generated tree, so a removed environment leaves nothing behind.
for tree in "${trees[@]}"; do
  read -r _ folder <<<"$tree"
  rm -rf clusters/*/"$folder"
  for built in "$staging/$folder"/*/; do
    cluster="$(basename "$built")"
    mkdir -p "clusters/$cluster"
    mv "$built" "clusters/$cluster/$folder"
  done
done
