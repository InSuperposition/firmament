setup_file() {
  export TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu"
  export TF_PLUGIN_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firmament/tofu-plugins"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  local root_directory
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  export environment_directory="$root_directory/environment/local"
  export components_directory="$root_directory/components"
  export TF_VAR_git_branch=feature/test

  tofu -chdir="$environment_directory" init -input=false -reconfigure \
    -backend-config="path=$BATS_FILE_TMPDIR/terraform.tfstate" >/dev/null
}

setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/local"
  mkdir -p "$BATS_TEST_ROOT"
}

# Prints the planned attributes of one resource address.
planned() {
  local address="$1"
  shift
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$environment_directory" plan -input=false -out="$plan" \
    -var="state_directory=$BATS_TEST_ROOT/state" "$@" >/dev/null
  tofu -chdir="$environment_directory" show -json "$plan" |
    jq --arg address "$address" '.resource_changes[] | select(.address == $address) | .change.after'
}

k0sctl_config() {
  planned module.orch_k0s.k0sctl_config.this "$@"
}

# Prints the values the bootstrap Job chart receives.
bootstrap_values() {
  planned module.bootstrap_flux.helm_release.this "$@" | jq -r '.values[0]'
}

cluster_config() {
  k0sctl_config "$@" | jq -r '.spec.k0s.config'
}

ssh_key_path() {
  k0sctl_config "$@" | jq -r '.spec.host[0].ssh[0].key_path'
}
