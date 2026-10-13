#!/usr/bin/env bats

load stubs.bash

setup() {
  setup_stubs
  fixtures="$root_directory/.mise/tests/scorecard"
  CLUSTER_OBJECTS="$BATS_TEST_TMPDIR/cluster.json"
  export CLUSTER_OBJECTS
  cp "$fixtures/cluster.json" "$CLUSTER_OBJECTS"
}

# Runs inventory:verify the way mise does for the local environment.
run_verify() {
  MISE_ENV=local TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" \
    run "$root_directory/.mise/tasks/inventory/verify.sh"
}

# Edits the cluster the stand-in kubectl prints with one jq filter.
change_cluster() {
  jq "$1" "$CLUSTER_OBJECTS" >"$CLUSTER_OBJECTS.new"
  mv "$CLUSTER_OBJECTS.new" "$CLUSTER_OBJECTS"
}

@test "inventory:verify passes a healthy cluster, one row per namespace" {
  run_verify
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(grep -c ' pass$' <<<"$output")" -eq 5 ]
  [[ "$output" == *"NAMESPACE"*"TENANT"*"RESULT"* ]]
}

@test "inventory:verify fails and names a namespace without its tenant label" {
  change_cluster '(.items[] | select(.kind == "Namespace" and .metadata.name == "cv") | .metadata.labels) = {}'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cv"*"namespace: tenant label is missing, the inventory says apps"* ]]
}

@test "inventory:verify fails and names a missing ResourceQuota" {
  change_cluster '.items |= map(select(.kind != "ResourceQuota" or .metadata.namespace != "cv"))'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cv"*"quota: ResourceQuota tenant is missing"* ]]
}

@test "inventory:verify fails and names a ResourceQuota that differs from the inventory" {
  change_cluster '(.items[] | select(.kind == "ResourceQuota" and .metadata.namespace == "cv") | .spec.hard["requests.cpu"]) = "9"'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"quota: ResourceQuota tenant allows cpu 9 and memory 4Gi, the inventory says cpu 2 and memory 4Gi"* ]]
}

@test "inventory:verify fails and names a missing network policy" {
  change_cluster '.items |= map(select(.kind != "CiliumNetworkPolicy" or .metadata.namespace != "openbao"))'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"openbao"*"policy: CiliumNetworkPolicy platform is missing"* ]]
}

@test "inventory:verify fails and names a HelmRelease that is not Ready" {
  change_cluster '(.items[] | select(.kind == "HelmRelease" and .metadata.name == "cert-manager") | .status.conditions[] | select(.type == "Ready") | .status) = "False"'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cert-manager"*"release: HelmRelease cert-manager is not Ready"* ]]
}

@test "inventory:verify fails and names a signed chart whose source is not verified" {
  change_cluster '(.items[] | select(.kind == "OCIRepository" and .metadata.name == "cv") | .status.conditions[] | select(.type == "SourceVerified") | .status) = "False"'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cv"*"chart: OCIRepository cv is not SourceVerified"* ]]
}

@test "inventory:verify does not demand a verified source of a chart with no verify block" {
  change_cluster '(.items[] | select(.kind == "OCIRepository" and .metadata.name == "openbao") | .status.conditions) = []'
  run_verify
  [ "$status" -eq 0 ] || fail "$output"
}

@test "inventory:verify fails and names a route that is not Accepted" {
  change_cluster '(.items[] | select(.kind == "HTTPRoute") | .status.parents[0].conditions[] | select(.type == "Accepted") | .status) = "False"'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"cv"*"route: HTTPRoute cv is not Accepted"* ]]
}

@test "inventory:verify fails and names a missing route for a package with ingress ports" {
  change_cluster '.items |= map(select(.kind != "HTTPRoute"))'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"route: no HTTPRoute, but a package lists ingress ports"* ]]
}

@test "inventory:verify reports the first failing check of a namespace and still checks the others" {
  change_cluster '.items |= map(select(.kind != "ResourceQuota" or .metadata.namespace != "cv")) | (.items[] | select(.kind == "HelmRelease" and .metadata.name == "openbao") | .status.conditions[] | select(.type == "Ready") | .status) = "False"'
  run_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"quota: ResourceQuota tenant is missing"* ]]
  [[ "$output" == *"release: HelmRelease openbao is not Ready"* ]]
}
