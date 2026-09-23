setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/ubuntu"
  export PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  module_directory="$root_directory/modules/os-ubuntu"

  tofu -chdir="$module_directory" init -backend=false -input=false -reconfigure >/dev/null
}

plan() {
  tofu -chdir="$module_directory" plan -input=false -var='ssh_target=fixture' "$@"
}
