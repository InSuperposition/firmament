#!/usr/bin/env bats
load setup.bash

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
