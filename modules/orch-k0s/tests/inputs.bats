#!/usr/bin/env bats
load setup.bash

@test "rejects a Helm chart without values" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "demo", "chartname": "example/demo", "version": "1.2.3", "namespace": "kube-system" }
    }
  ]
}
JSON
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *var.helm_charts* ]]
  [[ "$output" == *'"values"'* ]]
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
