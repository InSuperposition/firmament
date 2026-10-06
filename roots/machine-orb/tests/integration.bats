#!/usr/bin/env bats
load setup.bash

@test "reaches the machine with OrbStack's own SSH key by default" {
  run planned_output ssh_key_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.orbstack/ssh/id_ed25519" ]
}

@test "reaches the machine with the SSH key the caller sets" {
  run planned_output ssh_key_path -var='orbstack_ssh_key_path=/keys/id_ed25519'
  [ "$status" -eq 0 ]
  [ "$output" = /keys/id_ed25519 ]
}

@test "writes the machine-hosts contract into the environment's state directory" {
  local plan="$BATS_TEST_TMPDIR/plan.tfplan"
  tofu -chdir="$machine_root" plan -input=false -out="$plan" >/dev/null
  run bash -c "tofu -chdir='$machine_root' show -json '$plan' | jq -r '.resource_changes[] | select(.address == \"local_file.machine_hosts\") | .change.after.filename'"
  [ "$status" -eq 0 ]
  [ "$output" = "$TF_VAR_state_directory/machine-hosts.yaml" ]
}
