#!/usr/bin/env bats
load setup.bash

@test "explicit adoption records the validated existing machine" {
  existing_machine
  run bash "$adopt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .machine_id "$marker")" = '01M2WX3M540GRA73ECJ873RWCA' ]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "adoption does not create an absent machine" {
  run bash "$adopt"
  [ "$status" -eq 1 ]
  [ ! -f "$marker" ]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "failed validation preserves existing ownership" {
  owned_machine
  jq '.record.id = "replacement" | .record.image.arch = "amd64"' "$ORB_TEST_FIXTURE" >"$ORB_TEST_ROOT/machine.json"
  run bash "$adopt"
  [ "$status" -eq 1 ]
  [ "$(jq -r .machine_id "$marker")" = '01M2WX3M540GRA73ECJ873RWCA' ]
}

@test "explicit adoption can accept a valid same-name replacement" {
  owned_machine
  jq '.record.id = "replacement"' "$ORB_TEST_FIXTURE" >"$ORB_TEST_ROOT/machine.json"
  run bash "$adopt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .machine_id "$marker")" = replacement ]
}
