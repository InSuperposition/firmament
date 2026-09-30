setup_file() {
  export TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu"
  export TF_PLUGIN_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firmament/tofu-plugins"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  export environment_directory="$root_directory/environments/local"
  export components_directory="$root_directory/packages"
  export root_directory
  export TF_VAR_git_branch=feature/test

  tofu -chdir="$environment_directory" init -input=false -reconfigure \
    -backend-config="path=$BATS_FILE_TMPDIR/terraform.tfstate" >/dev/null
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$environment_directory/bootstrap" init \
    -input=false -reconfigure -backend-config="path=$BATS_FILE_TMPDIR/bootstrap.tfstate" >/dev/null
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

# Prints one planned output, with the names of values the plan cannot know
# yet mapped to true.
planned_output() {
  local name="$1" plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$environment_directory" plan -input=false -out="$plan" \
    -var="state_directory=$BATS_TEST_ROOT/state" >/dev/null
  tofu -chdir="$environment_directory" show -json "$plan" |
    jq --arg name "$name" '.output_changes[$name] | (.after_unknown // {}) + (.after // {})'
}

k0sctl_config() {
  planned module.orch_k0s.k0sctl_config.this "$@"
}

# Writes a state for the environment root holding what the bootstrap root
# reads from it: the runtime values the environment root plans, and the
# path of a kubeconfig for a cluster no test reaches.
environment_state() {
  local state="$BATS_TEST_ROOT/state" runtime_info
  mkdir -p "$state"
  cat >"$state/admin.kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters: [{name: test, cluster: {server: "https://127.0.0.1:1"}}]
users: [{name: test, user: {token: test}}]
contexts: [{name: test, context: {cluster: test, user: test}}]
current-context: test
KUBECONFIG
  runtime_info=$(planned_output runtime_info)
  jq -n --argjson runtime_info "$runtime_info" --arg kubeconfig "$state/admin.kubeconfig" '{
    version: 4, serial: 1, lineage: "test", terraform_version: "1.12.0", resources: [],
    outputs: {
      runtime_info: {value: $runtime_info, type: ["object", ($runtime_info | map_values("string"))]},
      kubeconfig_path: {value: $kubeconfig, type: "string"}
    }
  }' >"$state/terraform.tfstate"
}

# Prints the values the bootstrap Job chart receives, as the bootstrap root
# plans them against the environment root's values.
bootstrap_values() {
  local plan="$BATS_TEST_ROOT/bootstrap.tfplan"
  environment_state
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$environment_directory/bootstrap" plan \
    -input=false -refresh=false -out="$plan" -var="state_directory=$BATS_TEST_ROOT/state" >/dev/null
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$environment_directory/bootstrap" show -json "$plan" |
    jq -r '.resource_changes[] | select(.address == "module.bootstrap_flux.helm_release.this") | .change.after.values[0]'
}

cluster_config() {
  k0sctl_config "$@" | jq -r '.spec.k0s.config'
}

ssh_key_path() {
  k0sctl_config "$@" | jq -r '.spec.host[0].ssh[0].key_path'
}
