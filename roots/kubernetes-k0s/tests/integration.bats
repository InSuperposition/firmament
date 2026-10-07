#!/usr/bin/env bats
load setup.bash

@test "installs no Helm charts through k0s" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec | has("extensions")' <<<"$output")" = false ]
}

@test "keeps every in-cluster object out of the Kubernetes root" {
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$k0s_root" plan -input=false -out="$plan" >/dev/null
  run bash -c "tofu -chdir='$k0s_root' show -json '$plan' | jq -r '.resource_changes[].provider_name' | sort -u"
  [ "$status" -eq 0 ]
  [[ "$output" != *hashicorp/helm* ]]
  [[ "$output" != *hashicorp/kubernetes* ]]
}

@test "exposes the runtime values it gives Flux, for the cluster suites" {
  run planned_output runtime_info
  [ "$status" -eq 0 ]
  exposed=$(jq -r 'keys | .[]' <<<"$output" | sort)
  linted=$(grep -Ev '^[[:space:]]*(#|$)' "$root_directory/.mise/flux-test-values.env" | cut -d= -f1 | sort)
  [ "$exposed" = "$linted" ]
}

@test "renders the k0sctl configuration for the machine-hosts contract" {
  run k0sctl_file
  [ "$status" -eq 0 ]
  [ "$(jq -r '.filename' <<<"$output")" = "$TF_VAR_state_directory/k0sctl.yaml" ]
  config=$(jq -r '.content' <<<"$output")
  [ "$(yq -o=json '.spec.hosts[0].ssh' <<<"$config" | jq -c '{address, port, user, keyPath}')" = '{"address":"127.0.0.1","port":32222,"user":"root@firmament","keyPath":"/keys/id_ed25519"}' ]
  [ "$(yq '.metadata.name' <<<"$config")" = firmament ]
}

@test "trusts only the state directory's known_hosts, written from the contract's host keys" {
  run k0sctl_file
  [ "$status" -eq 0 ]
  [ "$(jq -r '.content' <<<"$output" | yq '.spec.hosts[0].ssh.options.UserKnownHostsFile')" = "$TF_VAR_state_directory/known_hosts" ]
  [ "$(jq -r '.content' <<<"$output" | yq '.spec.hosts[0].ssh.options.StrictHostKeyChecking')" = yes ]
  run planned local_file.known_hosts
  [ "$status" -eq 0 ]
  lines=$(jq -r '.content' <<<"$output")
  [ "$(wc -l <<<"$lines" | tr -d ' ')" -eq 2 ]
  [[ "$(sed -n 1p <<<"$lines")" == "[127.0.0.1]:32222 ssh-ed25519 "* ]]
  [[ "$(sed -n 2p <<<"$lines")" == "[127.0.0.1]:32222 ecdsa-sha2-nistp256 "* ]]
  [ "$(jq -r '.file_permission' <<<"$output")" = 0600 ]
}

@test "advertises the machine's IP and the allocation's pod CIDR" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.api.externalAddress' <<<"$output")" = 192.168.139.10 ]
  [ "$(yq '.spec.network.podCIDR' <<<"$output")" = 10.240.0.0/16 ]
  run planned_output runtime_info
  [ "$(jq -r '.api_address' <<<"$output")" = 192.168.139.10 ]
}

@test "writes the cluster-access contract only when told to publish it" {
  run tofu -chdir="$k0s_root" plan -input=false -no-color
  [ "$status" -eq 0 ]
  [[ "$output" != *"local_file.cluster_access[0]"* ]]
  run planned 'local_file.cluster_access[0]' -var=publish_cluster_access=true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.filename' <<<"$output")" = "$TF_VAR_state_directory/cluster-access.yaml" ]
  [ "$(jq -r '.content' <<<"$output" | yq -r '.kubeconfig_path')" = "$TF_VAR_state_directory/admin.kubeconfig" ]
}

@test "removes a published cluster-access contract in the next pass that does not publish" {
  apply_environment local
  TF_VAR_environment=local TF_VAR_environments_directory="$k0s_root/tests/fixtures/environments" \
    tofu -chdir="$k0s_root" apply -input=false -auto-approve -no-color -state="$BATS_TEST_TMPDIR/allocations.tfstate" -var=publish_cluster_access=true >/dev/null
  [ -f "$TF_VAR_state_directory/cluster-access.yaml" ]
  apply_environment local
  [ ! -e "$TF_VAR_state_directory/cluster-access.yaml" ]
}

@test "refuses a changed pod_cidr for an allocated cluster, naming it" {
  apply_environment local
  run plan_environment changed-pod-cidr
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"the allocation of cluster singularity is append-only"* ]]
}

@test "refuses a changed mesh_id for an allocated cluster, naming it" {
  apply_environment local
  run plan_environment changed-mesh-id
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"the allocation of cluster singularity is append-only"* ]]
}

@test "refuses a cluster removed from the data instead of marked retired" {
  apply_environment two-clusters
  run plan_environment local
  [ "$status" -ne 0 ]
  [[ "$output" == *"prevent_destroy"* ]]
}

@test "accepts a cluster marked retired, and keeps counting it" {
  apply_environment two-clusters
  run plan_environment retired-cluster
  [ "$status" -eq 0 ]
}

@test "refuses two clusters with the same mesh_id" {
  run plan_environment duplicate-mesh-id
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"every cluster needs its own mesh_id"* ]]
}

@test "refuses overlapping pod_cidr ranges" {
  run plan_environment overlapping-pod-cidr
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"pod_cidr ranges must not overlap"* ]]
}

@test "refuses a pod_cidr inside the service CIDR" {
  run plan_environment service-range-pod-cidr
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"must stay outside the service CIDR 10.96.0.0/12"* ]]
}

@test "refuses to run a retired cluster" {
  run plan_environment retired-selected
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"is retired, so it cannot run"* ]]
}

@test "forgets the allocation records with state rm, so destroy works" {
  apply_environment local
  run tofu -chdir="$k0s_root" destroy -input=false -auto-approve -no-color -state="$BATS_TEST_TMPDIR/allocations.tfstate"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prevent_destroy"* ]]
  tofu -chdir="$k0s_root" state rm -state="$BATS_TEST_TMPDIR/allocations.tfstate" 'terraform_data.allocation["singularity"]' >/dev/null
  run tofu -chdir="$k0s_root" destroy -input=false -auto-approve -no-color -state="$BATS_TEST_TMPDIR/allocations.tfstate" \
    -var=environment=local -var=environments_directory="$k0s_root/tests/fixtures/environments"
  [ "$status" -eq 0 ]
}

@test "refuses to plan without the machine-hosts contract" {
  rm "$TF_VAR_state_directory/machine-hosts.yaml"
  run tofu -chdir="$k0s_root" plan -input=false -no-color
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-hosts.yaml"* ]]
}

@test "the contract schema and the root refuse the same planted ssh.port, naming it" {
  local sample="$root_directory/contracts/machine-hosts/machine-hosts.yaml"
  yq -i '.ssh.port = "22"' "$TF_VAR_state_directory/machine-hosts.yaml"
  run tofu -chdir="$k0s_root" plan -input=false
  [ "$status" -ne 0 ]
  [[ "$output" == *"ssh.port"* ]] || {
    printf 'root: %s\n' "$output" >&2
    false
  }

  local data="$BATS_TEST_TMPDIR/machine-hosts.yaml"
  yq '.ssh.port = "22"' "$sample" >"$data"
  run cue vet -c -d '#Contract' "$root_directory/contracts/machine-hosts/schema.cue" "$data"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ssh.port"* ]] || {
    printf 'schema: %s\n' "$output" >&2
    false
  }
}
