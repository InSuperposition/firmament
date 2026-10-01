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
  mkdir -p "$TF_VAR_state_directory"
}

# Prints one output the machine root plans, as JSON.
planned_output() {
  local name="$1" plan="$BATS_TEST_TMPDIR/plan.tfplan"
  shift
  tofu -chdir="$machine_root" plan -input=false -out="$plan" "$@" >/dev/null
  tofu -chdir="$machine_root" show -json "$plan" | jq -r --arg name "$name" '.output_changes[$name].after'
}
