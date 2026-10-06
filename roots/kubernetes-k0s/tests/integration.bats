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

@test "destroys k0s with the machine instead of resetting it over SSH" {
  run k0sctl_config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.skip_destroy' <<<"$output")" = true ]
}

@test "never drains the single node before an upgrade" {
  run k0sctl_config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.no_drain' <<<"$output")" = true ]
}

@test "exposes the runtime values it gives Flux, for the cluster suites" {
  run planned_output runtime_info
  [ "$status" -eq 0 ]
  exposed=$(jq -r 'keys | .[]' <<<"$output" | sort)
  linted=$(grep -Ev '^[[:space:]]*(#|$)' "$root_directory/.mise/flux-test-values.env" | cut -d= -f1 | sort)
  [ "$exposed" = "$linted" ]
}

@test "reaches the machine through the machine-hosts contract" {
  run k0sctl_config
  [ "$status" -eq 0 ]
  ssh=$(jq -c '.spec.host[0].ssh[0] | {address, port, user, key_path}' <<<"$output")
  [ "$ssh" = '{"address":"127.0.0.1","port":32222,"user":"root@firmament","key_path":"/keys/id_ed25519"}' ]
  [ "$(cluster_config | yq -r '.metadata.name')" = firmament ]
}

@test "writes the cluster-access contract the bootstrap root reads" {
  run planned local_file.cluster_access
  [ "$status" -eq 0 ]
  [ "$(jq -r '.filename' <<<"$output")" = "$TF_VAR_state_directory/cluster-access.yaml" ]
  [ "$(jq -r '.content' <<<"$output" | yq -r '.kubeconfig_path')" = "$TF_VAR_state_directory/admin.kubeconfig" ]
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
