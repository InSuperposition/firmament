#!/usr/bin/env bats
load setup.bash

@test "accepts a host meeting the Ubuntu prerequisites" {
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *'version_id=26.04'* ]]
  [[ "$output" == *'btf=present'* ]]
}

@test "requires an explicit SSH target" {
  unset FIRMAMENT_SSH_TARGET
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *FIRMAMENT_SSH_TARGET* ]]
}

@test "rejects an Ubuntu version outside the supported target" {
  touch "$BATS_TEST_ROOT/ubuntu-24"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Ubuntu 26.04 is required'* ]]
}

@test "rejects a host without kernel BTF" {
  touch "$BATS_TEST_ROOT/no-btf"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Kernel BTF is required'* ]]
}

@test "propagates an SSH inspection failure" {
  touch "$BATS_TEST_ROOT/ssh-error"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Unable to inspect Ubuntu host'* ]]
}
