setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/orb"
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  orb_directory="$root_directory/modules/vm-orb"
  fixtures="$BATS_TEST_DIRNAME/fixtures"

  tofu -chdir="$orb_directory" init -backend=false -input=false -reconfigure >/dev/null
}

# Plans the module as a host whose home directory is the fixture named by
# $1 would, and writes the plan to $BATS_TEST_ROOT/plan.tfplan.
plan_with_home() {
  local home="$fixtures/$1"
  HOME="$home" tofu -chdir="$orb_directory" plan -input=false -no-color \
    -out="$BATS_TEST_ROOT/plan.tfplan" -var name=local-singularity
}

resource_after() {
  plan_with_home "${1:-home}" >/dev/null
  tofu -chdir="$orb_directory" show -json "$BATS_TEST_ROOT/plan.tfplan" |
    jq -c '.resource_changes[] | select(.address == "orbstack_machine.this") | .change.after'
}

# Prints one output the module plans, as JSON.
planned_output() {
  plan_with_home "${1:-home}" >/dev/null
  tofu -chdir="$orb_directory" show -json "$BATS_TEST_ROOT/plan.tfplan" |
    jq -c --arg name "$2" '.planned_values.outputs[$name].value'
}
