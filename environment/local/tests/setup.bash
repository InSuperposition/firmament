setup_file() {
  export TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu"
  export TF_PLUGIN_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firmament/tofu-plugins"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  local root_directory
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  export environment_directory="$root_directory/environment/local"

  tofu -chdir="$environment_directory" init -input=false -reconfigure \
    -backend-config="path=$BATS_FILE_TMPDIR/terraform.tfstate" >/dev/null
}

setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/local"
  mkdir -p "$BATS_TEST_ROOT"
}

cluster_config() {
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$environment_directory" plan -input=false -out="$plan" \
    -var='orbstack_ssh_key_path=/tmp/orbstack-test-key' \
    -var="state_directory=$BATS_TEST_ROOT/state" "$@" >/dev/null
  tofu -chdir="$environment_directory" show -json "$plan" |
    jq -r '.resource_changes[] | select(.address == "module.orch_k0s.k0sctl_config.this") | .change.after.spec.k0s.config'
}

cilium_values() {
  yq -r '.spec.extensions.helm.charts[] | select(.name == "cilium") | .values'
}
