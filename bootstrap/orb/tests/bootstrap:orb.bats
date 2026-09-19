#!/usr/bin/env bats
load setup.bash

@test "creates the absent target and records its returned identity" {
  run bash "$bootstrap"
  [ "$status" -eq 0 ]
  [ "$(jq -r .machine_id "$marker")" = '01M2WX3M540GRA73ECJ873RWCA' ]
  [[ "$output" == *'"name": "firmament"'* ]]
}

@test "rerunning an owned target does not create or modify it" {
  owned_machine
  run bash "$bootstrap"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name": "firmament"'* ]]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "an unmarked existing target requires explicit adoption" {
  existing_machine
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [[ "$output" == *orb:adopt* ]]
  [ ! -f "$marker" ]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "a same-name replacement cannot reuse the previous ownership" {
  owned_machine
  jq '.record.id = "replacement"' "$ORB_TEST_FIXTURE" >"$ORB_TEST_ROOT/machine.json"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [[ "$output" == *orb:adopt* ]]
  [ "$(jq -r .machine_id "$marker")" = '01M2WX3M540GRA73ECJ873RWCA' ]
}

@test "a mismatched owned target is rejected without changing ownership" {
  owned_machine
  jq '.record.config.cpu_limit = 2' "$ORB_TEST_FIXTURE" >"$ORB_TEST_ROOT/machine.json"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [[ "$output" == *configuration* ]]
  [ "$(jq -r .machine_id "$marker")" = '01M2WX3M540GRA73ECJ873RWCA' ]
}

@test "daemon failure never becomes permission to create" {
  touch "$ORB_TEST_ROOT/list-error"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [[ "$output" == *unavailable* ]]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
  [ ! -f "$marker" ]
}

@test "malformed discovery fails closed" {
  touch "$ORB_TEST_ROOT/bad-list"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "failed creation never records ownership" {
  touch "$ORB_TEST_ROOT/create-error"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [ ! -f "$marker" ]
}

@test "a missing previously-owned machine is not silently recreated" {
  owned_machine
  rm "$ORB_TEST_ROOT/machine.json"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  ! grep -q '^create ' "$ORB_TEST_ROOT/calls"
}

@test "concurrent bootstrap refuses the target lock" {
  mkdir -p "$(dirname "$marker")/.lock"
  run bash "$bootstrap"
  [ "$status" -eq 1 ]
  [[ "$output" == *lock* ]]
  [ ! -f "$ORB_TEST_ROOT/calls" ]
}

@test "invalid resource configuration fails before contacting OrbStack" {
  cp -R "$BATS_TEST_DIRNAME/.." "$BATS_TEST_TMPDIR/invalid-target"
  jq '.cpus = 0' "$BATS_TEST_DIRNAME/../machine.json" >"$BATS_TEST_TMPDIR/invalid-target/machine.json"
  run bash "$BATS_TEST_TMPDIR/invalid-target/scripts/bootstrap:orb.sh"
  [ "$status" -eq 1 ]
  [ ! -f "$ORB_TEST_ROOT/calls" ]
}
