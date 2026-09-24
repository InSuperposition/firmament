setup() {
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  module_directory="$root_directory/modules/cni-cilium"

  tofu -chdir="$module_directory" init -backend=false -input=false -reconfigure >/dev/null
}
