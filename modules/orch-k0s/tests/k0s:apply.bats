#!/usr/bin/env bats
load setup.bash

resource_after() {
  plan_json | jq -c '.resource_changes[] | select(.address == "k0sctl_config.this") | .change.after'
}

@test "plans connection values from the environment" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.host[0].ssh[0].address' <<<"$output")" = 127.0.0.1 ]
  [ "$(jq -r '.spec.host[0].ssh[0].user' <<<"$output")" = 'developer@firmament' ]
  [ "$(jq -r '.spec.host[0].ssh[0].port' <<<"$output")" = 32222 ]
  [ "$(jq -r '.spec.host[0].ssh[0].key_path' <<<"$output")" = /tmp/orbstack-test-key ]
  [ "$(jq -r '.spec.k0s.config' <<<"$output" | yq -r '.spec.api.externalAddress')" = firmament.orb.local ]
}

@test "preserves the declarative cluster contract" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.host[0].role' <<<"$output")" = 'controller+worker' ]
  [ "$(jq -r '.spec.host[0].no_taints' <<<"$output")" = true ]
  [ "$(jq -r '.spec.k0s.version' <<<"$output")" = '1.36.4+k0s.0' ]
  config=$(jq -r '.spec.k0s.config' <<<"$output")
  [ "$(yq -r '.spec.network.provider' <<<"$config")" = custom ]
  [ "$(yq -r '.spec.network.podCIDR' <<<"$config")" = 10.244.0.0/16 ]
  [ "$(yq -r '.spec.network.serviceCIDR' <<<"$config")" = 10.96.0.0/12 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$config")" = true ]
}

@test "requires every connection input" {
  unset FIRMAMENT_K0S_SSH_KEY
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *ssh_key_path* ]]
}

@test "rejects unsafe connection values" {
  export FIRMAMENT_K0S_SSH_ADDRESS='host with spaces'
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid SSH address'* ]]
}
