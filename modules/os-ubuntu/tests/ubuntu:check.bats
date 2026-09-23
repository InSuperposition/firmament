#!/usr/bin/env bats
load setup.bash

@test "accepts a host meeting the Ubuntu prerequisites" {
  run plan
  [ "$status" -eq 0 ]
}

@test "requires a non-empty SSH target" {
  run tofu -chdir="$module_directory" plan -input=false -var='ssh_target='
  [ "$status" -eq 1 ]
  [[ "$output" == *'ssh_target is required'* ]]
}

@test "rejects an Ubuntu version outside the supported target" {
  touch "$BATS_TEST_ROOT/ubuntu-24"
  run plan
  [ "$status" -eq 1 ]
  [[ "$output" == *'Ubuntu 26.04 is required'* ]]
}

@test "rejects a host without kernel BTF" {
  touch "$BATS_TEST_ROOT/no-btf"
  run plan
  [ "$status" -eq 1 ]
  [[ "$output" == *'Kernel BTF is required'* ]]
}

@test "propagates an SSH inspection failure" {
  touch "$BATS_TEST_ROOT/ssh-error"
  run plan
  [ "$status" -eq 1 ]
  [[ "$output" == *'Unable to inspect Ubuntu host'* ]]
}
