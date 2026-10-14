#!/usr/bin/env bats
load setup.bash

# Plans the module with every input except those named in $1 ("-" for none).
plan_without() {
  local omitted="$1" name
  local -A inputs=(
    [ssh_address]=$FIRMAMENT_K0S_SSH_ADDRESS
    [ssh_user]=$FIRMAMENT_K0S_SSH_USER
    [ssh_port]=$FIRMAMENT_K0S_SSH_PORT
    [ssh_key_path]=$FIRMAMENT_K0S_SSH_KEY
    [known_hosts_path]=$FIRMAMENT_K0S_KNOWN_HOSTS
    [api_address]=$FIRMAMENT_K0S_API_ADDRESS
    [pod_cidr]=$FIRMAMENT_K0S_POD_CIDR
  )
  local -a args=()
  for name in "${!inputs[@]}"; do
    [[ "$name" == "$omitted" ]] || args+=("-var=$name=${inputs[$name]}")
  done
  tofu -chdir="$k0s_directory" plan -input=false -no-color "${args[@]}"
}

@test "plans with every input" {
  run plan_without -
  [ "$status" -eq 0 ]
}

@test "requires every connection and network input" {
  local name
  for name in ssh_address ssh_user ssh_port ssh_key_path known_hosts_path api_address pod_cidr; do
    run plan_without "$name"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$name"* ]]
  done
}
