#!/usr/bin/env bats

load stubs.bash

# Each test runs contracts:lint on a small repository holding the real
# contracts/ folder and a valid set of packages, clusters and one
# environment, committed so the append-only rule has a last commit to
# compare with, after planting one violation.
#   cluster core runs net-cni (provides cni) and app-web (requires cni)
#   cluster edge runs net-cni and app-mirror (requires registry from the
#   mesh), and core's cluster.yaml provides registry
setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  export MISE_PROJECT_ROOT="$repository"
  mkdir -p "$repository"
  cp -R "$root_directory/contracts" "$repository/"
  package net-cni net 'provides: [{name: cni, ready: {kind: HelmRelease, name: net-cni}}]'
  package app-web app 'requires: [{name: cni}]
delta_keys: [replicas, resources.limits.memory]'
  package app-mirror app 'requires: [{name: cni}, {name: registry, scope: mesh}]'
  plant clusters/core/cluster.yaml 'role: trust
provides: [{name: registry, ready: {kind: HelmRelease, name: zot}}]'
  plant clusters/core/packages.yaml 'packages: [{name: net-cni}, {name: app-web}]'
  plant clusters/edge/cluster.yaml 'role: workload'
  plant clusters/edge/packages.yaml 'packages: [{name: net-cni}, {name: app-mirror}]'
  environment=environments/sample/environment.yaml
  mkdir -p "$repository/${environment%/*}"
  cp "$root_directory/contracts/environment-spec/samples/environment.yaml" "$repository/$environment"
  yq -i '.clusters = {"core": .clusters.covenant, "edge": .clusters.workload}
    | .mesh.allocations = {"core": .mesh.allocations.covenant, "edge": .mesh.allocations.workload}' \
    "$repository/$environment"
  plant environments/sample/deltas/core/app-web.yaml 'reason: two replicas fit here
values: {replicas: 2}'
  git -C "$repository" init -q
  git -C "$repository" add -A
  git -C "$repository" -c user.name=test -c user.email=test@example.test commit -q -m start
}

plant() {
  mkdir -p "$repository/$(dirname -- "$1")"
  printf '%s\n' "$2" >"$repository/$1"
}

# Writes packages/<name>/package.yaml with a valid pin and the given
# requires, provides or delta_keys lines.
package() {
  plant "packages/$1/package.yaml" "name: $1
layer: $2
source: {source: oci://example.test/$1, version: 1.0.0, digest: sha256:$(printf '%064d' 1)}
namespace: $1
$3"
}

lint() {
  run "$root_directory/.mise/tasks/contracts/lint.sh"
}

assert_violation() {
  [ "$status" -eq 1 ]
  [[ "$output" == *"contracts:lint: $1: $2:"* ]] || {
    printf 'expected %s: %s in:\n%s\n' "$1" "$2" "$output" >&2
    return 1
  }
}

@test "accepts a valid set of packages, clusters and an environment" {
  lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "accepts the repository itself, samples included" {
  MISE_PROJECT_ROOT="$root_directory" run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ]
}

@test "rejects a pin without a digest and names the field" {
  yq -i '.source.digest = "latest"' "$repository/packages/app-web/package.yaml"
  lint
  assert_violation packages/app-web/package.yaml shape
  [[ "$output" == *"source.digest: invalid value"* ]]
}

@test "rejects a mutated sample and names the field" {
  yq -i '.api.port = 70000' "$repository/contracts/cluster-access/samples/cluster-access.yaml"
  lint
  assert_violation contracts/cluster-access/samples/cluster-access.yaml shape
  [[ "$output" == *"api.port"* ]]
}

@test "rejects a sample glob that matches no file" {
  rm "$repository/contracts/machine-hosts/samples/machine-hosts.yaml"
  lint
  assert_violation contracts/layout/layout.yaml shape
  [[ "$output" == *"machine-hosts.yaml matches no file"* ]]
}

@test "rejects a provider without a readiness check" {
  yq -i 'del(.provides[0].ready)' "$repository/packages/net-cni/package.yaml"
  lint
  assert_violation packages/net-cni/package.yaml shape
  [[ "$output" == *"provides.0.ready: field is required"* ]]
}

@test "rejects a requirement no package of the cluster provides" {
  plant clusters/core/packages.yaml 'packages: [{name: app-web}]'
  lint
  assert_violation packages/app-web/package.yaml requirements-met-once
  [[ "$output" == *"cni is provided 0 times in cluster core"* ]]
}

@test "rejects a requirement two packages of the cluster provide" {
  package net-other net 'provides: [{name: cni, ready: {kind: HelmRelease, name: net-other}}]'
  plant clusters/core/packages.yaml 'packages: [{name: net-cni}, {name: net-other}, {name: app-web}]'
  lint
  assert_violation packages/app-web/package.yaml requirements-met-once
  [[ "$output" == *"cni is provided 2 times in cluster core"* ]]
}

@test "rejects a cluster that lists a package without package.yaml" {
  plant clusters/core/packages.yaml 'packages: [{name: net-cni}, {name: app-web}, {name: app-gone}]'
  lint
  assert_violation clusters/core/packages.yaml requirements-met-once
  [[ "$output" == *"lists app-gone, which has no packages/app-gone/package.yaml"* ]]
}

@test "rejects packages that depend on each other in a cycle" {
  package net-cni net 'provides: [{name: cni, ready: {kind: HelmRelease, name: net-cni}}]
requires: [{name: web}]'
  package app-web app 'requires: [{name: cni}]
provides: [{name: web, ready: {kind: Deployment, name: web}}]
delta_keys: [replicas]'
  lint
  assert_violation clusters/core/packages.yaml no-cycles
  [[ "$output" == *"app-web"* && "$output" == *"net-cni"* ]]
}

@test "accepts a mesh requirement another cluster of the environment provides" {
  lint
  [ "$status" -eq 0 ]
}

@test "rejects a mesh requirement no other cluster of the environment provides" {
  plant clusters/core/cluster.yaml 'role: trust'
  lint
  assert_violation packages/app-mirror/package.yaml mesh-requirements-met-once
  [[ "$output" == *"registry is provided 0 times by the other clusters of $environment"* ]]
}

@test "rejects a delta key the package does not declare" {
  plant environments/sample/deltas/core/app-web.yaml 'reason: more memory
values: {resources: {limits: {cpu: 2}}}'
  lint
  assert_violation environments/sample/deltas/core/app-web.yaml delta-keys-declared
  [[ "$output" == *"resources.limits.cpu is not in the package delta_keys"* ]]
}

@test "accepts a nested delta key the package declares" {
  plant environments/sample/deltas/core/app-web.yaml 'reason: more memory
values: {resources: {limits: {memory: 1Gi}}}'
  lint
  [ "$status" -eq 0 ]
}

@test "rejects a delta for a package the cluster does not run" {
  plant environments/sample/deltas/edge/app-web.yaml 'reason: none
values: {replicas: 1}'
  lint
  assert_violation environments/sample/deltas/edge/app-web.yaml delta-keys-declared
}

@test "rejects a delta without a reason" {
  plant environments/sample/deltas/core/app-web.yaml 'values: {replicas: 2}'
  lint
  assert_violation environments/sample/deltas/core/app-web.yaml shape
  [[ "$output" == *"reason: field is required"* ]]
}

@test "rejects two clusters with the same mesh id" {
  yq -i '.mesh.allocations.edge.id = 1' "$repository/$environment"
  lint
  assert_violation "$environment" shape
  [[ "$output" == *"UniqueItems"* ]]
}

@test "rejects a cluster without a mesh allocation" {
  yq -i '.clusters.extra = .clusters.edge | .budget.memory_mib = 20000' "$repository/$environment"
  lint
  assert_violation "$environment" shape
  [[ "$output" == *"mesh.allocations.extra.id: field is required"* ]]
}

@test "rejects overlapping pod CIDRs" {
  yq -i '.mesh.allocations.late = {"id": 9, "pod_cidr": "10.241.128.0/17"}' "$repository/$environment"
  lint
  assert_violation "$environment" mesh-allocations
  [[ "$output" == *"pod CIDR 10.241.0.0/16 of edge overlaps pod CIDR 10.241.128.0/17 of late"* ]]
}

@test "rejects a pod CIDR inside a service CIDR" {
  yq -i '.mesh.allocations.late = {"id": 9, "pod_cidr": "10.100.0.0/16"}' "$repository/$environment"
  lint
  assert_violation "$environment" mesh-allocations
  [[ "$output" == *"overlaps service CIDR 10.96.0.0/12"* ]]
}

@test "rejects an allocation removed since the last commit" {
  yq -i 'del(.clusters.edge) | del(.mesh.allocations.edge)' "$repository/$environment"
  lint
  assert_violation "$environment" mesh-allocations
  [[ "$output" == *"allocation edge (id 2, 10.241.0.0/16) disappeared"* ]]
}

@test "rejects an allocation changed since the last commit" {
  yq -i '.mesh.allocations.edge.pod_cidr = "10.242.0.0/16"' "$repository/$environment"
  lint
  assert_violation "$environment" mesh-allocations
  [[ "$output" == *"allocation edge changed from id 2, 10.241.0.0/16"* ]]
}

@test "accepts a retired cluster that keeps its allocation, and a new allocation" {
  yq -i 'del(.clusters.edge) | .mesh.allocations.late = {"id": 3, "pod_cidr": "10.242.0.0/16"}' "$repository/$environment"
  plant environments/sample/deltas/core/app-web.yaml 'reason: two replicas fit here
values: {replicas: 2}'
  rm -r "$repository/clusters/edge"
  lint
  [ "$status" -eq 0 ]
}

@test "rejects machines whose memory exceeds the budget" {
  yq -i '.budget.memory_mib = 8192' "$repository/$environment"
  lint
  assert_violation "$environment" shape
  [[ "$output" == *"_machineMemoryFitsBudget: invalid value 10240 (out of bound <=8192)"* ]]
}

@test "checks nothing when the layout lists no contract files" {
  yq -i 'del(.contract_files)' "$repository/contracts/layout/layout.yaml"
  rm -r "$repository/clusters" "$repository/environments"
  lint
  [ "$status" -eq 0 ]
}
