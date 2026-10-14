#!/usr/bin/env bats
load setup.bash

@test "declares the machine from its name and the image, with no host pins" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = local-singularity ]
  [ "$(jq -r '.image' <<<"$output")" = ubuntu:resolute ]
  [ "$(jq -r '.arch' <<<"$output")" = null ]
  [ "$(jq -r '.username' <<<"$output")" = null ]
}

@test "reaches the machine as the host's default user through the orb alias" {
  run planned_output home ssh_target
  [ "$status" -eq 0 ]
  [ "$output" = '"local-singularity@orb"' ]
}

@test "reaches the machine as root through OrbStack's proxy with its own client key" {
  run planned_output home ssh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.address' <<<"$output")" = 127.0.0.1 ]
  [ "$(jq -r '.port' <<<"$output")" -eq 32222 ]
  [ "$(jq -r '.user' <<<"$output")" = root@local-singularity ]
  [ "$(jq -r '.key_path' <<<"$output")" = "$fixtures/home/.orbstack/ssh/id_ed25519" ]
}

@test "outputs only the proxy's server keys, without the host column" {
  run planned_output home ssh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.host_keys | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.host_keys[0]' <<<"$output")" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" ]
  [[ "$(jq -r '.host_keys[1]' <<<"$output")" == ecdsa-sha2-nistp256\ * ]]
}

@test "fails naming the file when OrbStack has no known_hosts" {
  run plan_with_home home-no-file
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *".orbstack/ssh/known_hosts has no key for [127.0.0.1]:32222"* ]]
}

@test "fails naming the file when known_hosts holds no key for the proxy" {
  run plan_with_home home-other-hosts
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *".orbstack/ssh/known_hosts has no key for [127.0.0.1]:32222"* ]]
}

@test "plan is offline — no live OrbStack calls" {
  local orb_dir
  orb_dir=$(dirname -- "$(command -v orb)")
  local filtered_path=""
  local segment
  IFS=':' read -ra segments <<<"$PATH"
  for segment in "${segments[@]}"; do
    [ "$segment" = "$orb_dir" ] && continue
    filtered_path="${filtered_path:+$filtered_path:}$segment"
  done
  PATH="$filtered_path" run resource_after
  [ "$status" -eq 0 ]
}
