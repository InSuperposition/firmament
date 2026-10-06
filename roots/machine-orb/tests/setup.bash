setup_file() {
  export TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu"
  mkdir -p "${TF_PLUGIN_CACHE_DIR:?run this through mise}"
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  export machine_root="$root_directory/roots/machine-orb"
  tofu -chdir="$machine_root" init -input=false -reconfigure \
    -backend-config="path=$BATS_FILE_TMPDIR/machine-orb.tfstate" >/dev/null
}

setup() {
  export TF_VAR_state_directory="$BATS_TEST_TMPDIR/state"
  export TF_VAR_environment=local
  export TF_VAR_environments_directory="$BATS_TEST_DIRNAME/fixtures/environments"
  mkdir -p "$TF_VAR_state_directory"
}

# Plans the machine root as a host whose home directory is the fixture would,
# writing the plan to $BATS_TEST_TMPDIR/plan.tfplan.
plan_machine_root() {
  HOME="$BATS_TEST_DIRNAME/fixtures/home" tofu -chdir="$machine_root" plan -input=false -no-color \
    -out="$BATS_TEST_TMPDIR/plan.tfplan" "$@"
}

# Prints one output the machine root plans, as JSON.
planned_output() {
  local name="$1"
  shift
  plan_machine_root "$@" >/dev/null
  tofu -chdir="$machine_root" show -json "$BATS_TEST_TMPDIR/plan.tfplan" | jq -c --arg name "$name" '.output_changes[$name].after'
}
