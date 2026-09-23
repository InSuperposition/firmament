setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/orb"
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  orb_directory="$root_directory/modules/vm-orb"

  tofu -chdir="$orb_directory" init -backend=false -input=false -reconfigure >/dev/null
}

resource_after() {
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$orb_directory" plan -input=false -out="$plan" >/dev/null
  tofu -chdir="$orb_directory" show -json "$plan" |
    jq -c '.resource_changes[] | select(.address == "orbstack_machine.this") | .change.after'
}
