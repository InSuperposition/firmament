#!/usr/bin/env bats
load setup.bash

@test "names the machine <environment>-<cluster>" {
  run planned_output machine_name
  [ "$status" -eq 0 ]
  [ "$output" = '"local-singularity"' ]
}

@test "refuses a cluster the environment does not allocate, naming the file" {
  TF_VAR_environment=unallocated run plan_machine_root
  [ "$status" -ne 0 ]
  [[ "$(tr -s ' \n' '  ' <<<"$output")" == *"unallocated/environment.yaml: clusters must hold an allocation for the cluster missing"* ]]
}

@test "writes the machine-hosts contract into the environment's state directory" {
  plan_machine_root >/dev/null
  run bash -c "tofu -chdir='$machine_root' show -json '$BATS_TEST_TMPDIR/plan.tfplan' | jq -r '.resource_changes[] | select(.address == \"local_file.machine_hosts\") | .change.after.filename'"
  [ "$status" -eq 0 ]
  [ "$output" = "$TF_VAR_state_directory/machine-hosts.yaml" ]
}

@test "the machine-name helper the stall task uses equals the planned machine name" {
  planned=$(planned_output machine_name | jq -r '.')
  helper=$(MISE_ENV=local MISE_PROJECT_ROOT="$machine_root/../.." bash -c 'source "$MISE_PROJECT_ROOT/.mise/lib.sh" && machine_name')
  [ "$helper" = "$planned" ]
}
