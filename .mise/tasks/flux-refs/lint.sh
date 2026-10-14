#!/usr/bin/env bash
#MISE description="Check offline that every Flux Kustomization's dependsOn, spec.path and healthChecks resolve, and that the published artifact carries each path; changes nothing"
set -euo pipefail
cd "${MISE_PROJECT_ROOT:?}"

readonly publish_workflow=".github/workflows/publish.yaml"
readonly trees_file=".mise/render-trees.yaml"

status=0
problem() {
  printf '%s\n' "$*" >&2
  status=1
}

mapfile -t generated_folders < <(yq -r '.trees[].folder' "$trees_file")
if ((${#generated_folders[@]} == 0)); then
  problem "$trees_file lists no generated folder"
fi

# The folders the artifact keeps: every '!' entry of the --ignore-paths
# argument on the flux push artifact line.
published_folders() {
  local line patterns entry
  line="$(grep -E 'flux push artifact' "$publish_workflow" || true)"
  patterns="$(sed -nE "s/.*--ignore-paths '([^']*)'.*/\1/p" <<<"$line")"
  if [[ -z "$patterns" ]]; then
    problem "$publish_workflow: no flux push artifact line with --ignore-paths '<patterns>' (the check reads the published folders from it)"
    return
  fi
  local -a entries
  IFS=',' read -ra entries <<<"$patterns"
  for entry in "${entries[@]}"; do
    [[ "$entry" == '!'* ]] && printf '%s\n' "${entry#!}"
  done
  return 0
}

mapfile -t kept < <(published_folders)
if ((${#kept[@]} == 0)); then
  problem "$publish_workflow: --ignore-paths keeps no folder"
fi

is_published() {
  local folder
  for folder in "${kept[@]}"; do
    [[ "/$1" == "$folder"* ]] && return 0
  done
  return 1
}

is_generated_folder() {
  local folder
  for folder in "${generated_folders[@]}"; do
    [[ "$1" == "$folder" ]] && return 0
  done
  return 1
}

# Prints every HelmRelease of a build as "<namespace>/<name>". A folder with
# a kustomization.yaml is built; any other holds plain manifests.
helm_releases_in() {
  local source_folder="$1"
  if [[ -f "$source_folder/kustomization.yaml" ]]; then
    kubectl kustomize "$source_folder"
  else
    local manifest
    while IFS= read -r manifest; do
      printf -- '---\n'
      cat "$manifest"
    done < <(find "$source_folder" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  fi | yq -N 'select(.kind == "HelmRelease") | .metadata.namespace + "/" + .metadata.name'
}

check_health_checks() {
  local file="$1" name="$2" source_folder="$3" wanted="$4" present
  [[ -z "$wanted" ]] && return 0
  present="$(helm_releases_in "$source_folder")"
  local -a wanted_list
  IFS=',' read -ra wanted_list <<<"$wanted"
  for release in "${wanted_list[@]}"; do
    grep -qxF "$release" <<<"$present" ||
      problem "$file: Kustomization $name waits for HelmRelease $release, which $source_folder does not build"
  done
}

check_path() {
  local file="$1" name="$2" path="$3" cluster="$4" health="$5" folder environment_folder
  path="${path#./}"
  if [[ "$path" =~ ^clusters/([^/]+)/([^/]+)/\$\{environment\}$ ]]; then
    folder="${BASH_REMATCH[2]}"
    if [[ "${BASH_REMATCH[1]}" != "$cluster" ]] || ! is_generated_folder "$folder"; then
      problem "$file: Kustomization $name has path $path, which $trees_file does not generate for $cluster"
      return
    fi
    is_published "$path" || problem "$file: Kustomization $name has path $path, which $publish_workflow does not publish"
    if [[ -d "clusters/$cluster/$folder" ]]; then
      for environment_folder in "clusters/$cluster/$folder"/*/; do
        check_health_checks "$file" "$name" "${environment_folder%/}" "$health"
      done
    else
      printf '%s: Kustomization %s: clusters/%s/%s is not rendered; its healthChecks were not checked (run mise run render)\n' "$file" "$name" "$cluster" "$folder" >&2
    fi
    return
  fi
  if [[ "$path" == *\$\{* ]]; then
    problem "$file: Kustomization $name has path $path with a variable the check cannot resolve"
    return
  fi
  if [[ -z "$(git ls-files -- "$path")" ]]; then
    problem "$file: Kustomization $name has path $path, which holds no tracked file"
    return
  fi
  is_published "$path" || problem "$file: Kustomization $name has path $path, which $publish_workflow does not publish"
  check_health_checks "$file" "$name" "$path" "$health"
}

check_cluster() {
  local flux_folder="$1" cluster file entry name path depends health dependency folder
  cluster="$(basename "$(dirname "$flux_folder")")"
  local -a names=() entries=()

  for folder in "${generated_folders[@]}"; do
    [[ -z "$(git ls-files -- "clusters/$cluster/$folder")" ]] ||
      problem "clusters/$cluster/$folder is generated but holds tracked files"
    git check-ignore -q "clusters/$cluster/$folder/environment/file.yaml" ||
      problem "clusters/$cluster/$folder is generated but .gitignore does not ignore it"
  done

  local -a listed
  mapfile -t listed < <(yq -r '.resources[]' "$flux_folder/kustomization.yaml")
  for file in "$flux_folder"/*.yaml; do
    [[ "$(basename "$file")" == kustomization.yaml ]] && continue
    printf '%s\n' "${listed[@]}" | grep -qxF "$(basename "$file")" ||
      problem "$file is not listed in $flux_folder/kustomization.yaml"
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      names+=("${entry%%|*}")
      entries+=("$file|$entry")
    done < <(yq -N 'select(.kind == "Kustomization" and (.apiVersion | test("^kustomize.toolkit.fluxcd.io/"))) | [.metadata.name, .spec.path, ((.spec.dependsOn // []) | map(.name) | join(",")), ((.spec.healthChecks // []) | map(select(.kind == "HelmRelease") | .namespace + "/" + .name) | join(","))] | join("|")' "$file")
  done

  for entry in "${entries[@]}"; do
    IFS='|' read -r file name path depends health <<<"$entry"
    if [[ -n "$depends" ]]; then
      local -a dependency_list
      IFS=',' read -ra dependency_list <<<"$depends"
      for dependency in "${dependency_list[@]}"; do
        printf '%s\n' "${names[@]}" | grep -qxF "$dependency" ||
          problem "$file: Kustomization $name depends on $dependency, which no Kustomization in $flux_folder defines"
      done
    fi
    check_path "$file" "$name" "$path" "$cluster" "$health"
  done
}

mapfile -t flux_folders < <(find clusters -mindepth 2 -maxdepth 2 -type d -name flux | sort)
if ((${#flux_folders[@]} == 0)); then
  problem "no clusters/*/flux folder to check"
fi
for flux_folder in "${flux_folders[@]}"; do
  check_cluster "$flux_folder"
done
exit "$status"
