#!/usr/bin/env bash
#MISE description="Validate every contract data file against its CUE schema, then check the rules that span files: requirements met exactly once, no dependency cycle, declared delta keys, and append-only, non-overlapping mesh allocations; changes nothing"
set -euo pipefail

# Every rule prints one line per violation as "<file>: <rule>: <detail>";
# CUE's own messages follow a shape violation, indented. The rules read
# the files git tracks or would track.
root="${MISE_PROJECT_ROOT:?}"
layout="$root/contracts/layout/layout.yaml"

repository_files() {
  git -C "$root" ls-files -co --exclude-standard -- "$@" |
    while IFS= read -r file; do
      [[ -f "$root/$file" ]] && printf '%s\n' "$file"
    done
}

# Prints a YAML file as JSON, or null when it does not exist.
json_of() {
  if [[ -f "$root/$1" ]]; then
    yq -o=json -I=0 '.' "$root/$1"
  else
    printf 'null\n'
  fi
}

# Validates each file a contract_files glob matches against its definition.
# A glob under contracts/ names a sample, so it must match a file.
rule_shape() {
  local glob contract definition file errors
  while IFS=$'\t' read -r glob contract definition; do
    # An empty glob would match every file.
    [[ -n "$glob" ]] || continue
    mapfile -t files < <(repository_files ":(glob)$glob")
    if ((${#files[@]} == 0)) && [[ "$glob" == contracts/* ]]; then
      printf 'contracts/layout/layout.yaml: shape: sample %s matches no file\n' "$glob"
      continue
    fi
    for file in "${files[@]}"; do
      if ! errors=$(cd "$root/contracts" && cue vet -c -d "$definition" "./$contract" "$root/$file" 2>&1); then
        printf '%s: shape: does not satisfy %s %s\n' "$file" "$contract" "$definition"
        mapfile -t lines <<<"${errors//"$root"\//}"
        printf '    %s\n' "${lines[@]}"
      fi
    done
  done < <(yq -r '.contract_files[] | [.glob, .contract, .definition] | @tsv' "$layout")
}

# Prints one JSON object per cluster folder:
# {cluster, cluster_file, packages: [{name, file, spec}]}. A package the
# cluster lists without a package.yaml has spec null.
clusters_json() {
  local folder cluster names name
  for folder in "$root"/clusters/*/; do
    [[ -f "$folder/packages.yaml" ]] || continue
    cluster=$(basename "$folder")
    names=$(yq -r '.packages[].name' "$folder/packages.yaml")
    {
      printf '{"cluster": "%s", "cluster_file": %s, "packages": [' "$cluster" "$(json_of "clusters/$cluster/cluster.yaml")"
      local first=1
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        ((first)) || printf ','
        first=0
        printf '{"name": "%s", "spec": %s}' "$name" "$(json_of "packages/$name/package.yaml")"
      done <<<"$names"
      printf ']}\n'
    }
  done
}

# Within one cluster, each requirement of scope cluster, from a package or
# from cluster.yaml, is provided exactly once by its packages or by
# cluster.yaml.
rule_requirements_met_once() {
  clusters_json | jq -r '
    . as $c
    | ([$c.packages[] | select(.spec == null)
        | "clusters/\($c.cluster)/packages.yaml: requirements-met-once: lists \(.name), which has no packages/\(.name)/package.yaml"]) as $missing
    | ([$c.packages[] | select(.spec != null) | .spec.provides[]?.name]
        + [$c.cluster_file.provides[]?.name]) as $provided
    | ([$c.packages[] | select(.spec != null) | {who: "packages/\(.name)/package.yaml", r: .spec.requires[]?}]
        + [{who: "clusters/\($c.cluster)/cluster.yaml", r: $c.cluster_file.requires[]?}]
        | map(select((.r.scope // "cluster") == "cluster"))) as $requirements
    | $missing[],
      ($requirements[]
        | . as $q
        | ([$provided[] | select(. == $q.r.name)] | length) as $n
        | select($n != 1)
        | "\($q.who): requirements-met-once: \($q.r.name) is provided \($n) times in cluster \($c.cluster)")'
}

# Within one cluster, a package that requires what another package provides
# depends on it; the dependencies must form no cycle. tsort reports a cycle
# on stderr (and on macOS still exits 0), so its stderr is what counts.
rule_no_cycles() {
  local cluster edges cycle
  while IFS=$'\t' read -r cluster edges; do
    [[ -n "$edges" ]] || continue
    cycle=$(tr ' ' '\n' <<<"$edges" | paste -d ' ' - - | tsort 2>&1 >/dev/null | grep -v 'cycle in data' | sed 's/^tsort: //' | paste -sd ' ' -) || true
    [[ -z "$cycle" ]] ||
      printf 'clusters/%s/packages.yaml: no-cycles: packages depend on each other in a cycle: %s\n' "$cluster" "$cycle"
  done < <(clusters_json | jq -r '
    . as $c
    | [$c.packages[] | select(.spec != null)] as $specs
    | [ $specs[] as $a | $a.spec.requires[]? | select((.scope // "cluster") == "cluster") as $r
        | $specs[] as $b | select($b.name != $a.name) | select(any($b.spec.provides[]?; .name == $r.name))
        | "\($a.name) \($b.name)" ]
    | [$c.cluster, join(" ")] | @tsv')
}

# Within one environment, each requirement of scope mesh of a cluster is
# provided exactly once by the environment's other clusters.
rule_mesh_requirements_met_once() {
  local file environment
  while IFS= read -r file; do
    environment=$(json_of "$file")
    clusters_json | jq -rs --arg file "$file" --argjson environment "$environment" '
      [.[] | select(.cluster as $n | $environment.clusters | has($n))] as $members
      | $members[] as $c
      | ([$c.packages[] | select(.spec != null) | {who: "packages/\(.name)/package.yaml", r: .spec.requires[]?}]
          + [{who: "clusters/\($c.cluster)/cluster.yaml", r: $c.cluster_file.requires[]?}]
          | map(select(.r.scope == "mesh")))[]
      | . as $q
      | ([$members[] | select(.cluster != $c.cluster)
          | ([.packages[] | select(.spec != null) | .spec.provides[]?.name] + [.cluster_file.provides[]?.name])[]
          | select(. == $q.r.name)] | length) as $n
      | select($n != 1)
      | "\($q.who): mesh-requirements-met-once: \($q.r.name) is provided \($n) times by the other clusters of \($file)"'
  done < <(repository_files ':(glob)environments/*/environment.yaml')
}

# A delta sets only keys its package declares in delta_keys, for a package
# its cluster runs.
rule_delta_keys_declared() {
  local file cluster package allowed
  while IFS= read -r file; do
    cluster=$(basename "$(dirname "$file")")
    package=$(basename "$file" .yaml)
    if ! yq -e ".packages[] | select(.name == \"$package\")" "$root/clusters/$cluster/packages.yaml" >/dev/null 2>&1; then
      printf '%s: delta-keys-declared: cluster %s does not run package %s\n' "$file" "$cluster" "$package"
      continue
    fi
    allowed=$(json_of "packages/$package/package.yaml" | jq -c '.delta_keys // []')
    json_of "$file" | jq -r --arg file "$file" --argjson allowed "$allowed" '
      .values | paths(scalars) | map(tostring) | join(".")
      | select(. as $k | $allowed | index($k) | not)
      | "\($file): delta-keys-declared: \(.) is not in the package delta_keys"'
  done < <(repository_files ':(glob)environments/*/deltas/*/*.yaml')
}

# Mesh allocations: pod CIDRs do not overlap each other or any cluster's
# service CIDR, and every allocation of the last commit is still present
# with the same id and pod CIDR.
rule_mesh_allocations() {
  local file committed
  while IFS= read -r file; do
    committed=$(git -C "$root" show "HEAD:$file" 2>/dev/null | yq -o=json -I=0 '.' 2>/dev/null) || committed=null
    [[ -n "$committed" ]] || committed=null
    json_of "$file" | jq -r --arg file "$file" --argjson committed "$committed" '
      def ip: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
      def range: split("/") as [$a, $b] | ($a | ip) as $s | [$s, $s + pow(2; 32 - ($b | tonumber)) - 1];
      def overlap($x; $y): ($x | range) as $p | ($y | range) as $q | $p[0] <= $q[1] and $q[0] <= $p[1];
      (.mesh.allocations // {}) as $now
      | ([$now | to_entries[] | {name: .key, cidr: .value.pod_cidr, what: "pod"}]
          + [.clusters // {} | to_entries[] | {name: .key, cidr: .value.service_cidr, what: "service"}]) as $ranges
      | ([$ranges | to_entries[] | .key as $i | .value as $a
          | $ranges[($i + 1):][] as $b
          | select($a.what == "pod" or $b.what == "pod")
          | select(overlap($a.cidr; $b.cidr))
          | "\($file): mesh-allocations: \($a.what) CIDR \($a.cidr) of \($a.name) overlaps \($b.what) CIDR \($b.cidr) of \($b.name)"]),
        ([($committed.mesh.allocations // {}) | to_entries[]
          | . as $old
          | if ($now | has($old.key) | not) then
              "\($file): mesh-allocations: allocation \($old.key) (id \($old.value.id), \($old.value.pod_cidr)) disappeared; allocations are append-only"
            elif $now[$old.key].id != $old.value.id or $now[$old.key].pod_cidr != $old.value.pod_cidr then
              "\($file): mesh-allocations: allocation \($old.key) changed from id \($old.value.id), \($old.value.pod_cidr); allocations are append-only"
            else empty end])
      | .[]'
  done < <(repository_files ':(glob)environments/*/environment.yaml' ':(glob)contracts/environment-spec/samples/environment.yaml')
}

violations=$(
  rule_shape
  rule_requirements_met_once
  rule_no_cycles
  rule_mesh_requirements_met_once
  rule_delta_keys_declared
  rule_mesh_allocations
)
if [[ -n "$violations" ]]; then
  mapfile -t lines <<<"$violations"
  printf 'contracts:lint: %s\n' "${lines[@]}" >&2
  exit 1
fi
