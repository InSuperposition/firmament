setup_file() {
  export TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu"
  mkdir -p "${TF_PLUGIN_CACHE_DIR:?run this through mise}"
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  export k0s_root="$root_directory/roots/kubernetes-k0s"
  export bootstrap_root="$root_directory/roots/bootstrap-flux"
  export payload_build="$root_directory/clusters/singularity/payload"
  export packages_directory="$root_directory/packages"
  export root_directory
  export TF_VAR_git_branch=feature/test
  export TF_VAR_git_commit=0123456789abcdef0123456789abcdef01234567
  export TF_VAR_environment=local

  tofu -chdir="$k0s_root" init -input=false -reconfigure \
    -backend-config="path=$BATS_FILE_TMPDIR/kubernetes-k0s.tfstate" >/dev/null
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$bootstrap_root" init \
    -input=false -reconfigure -backend-config="path=$BATS_FILE_TMPDIR/bootstrap-flux.tfstate" >/dev/null
}

# Each test plans against its own state directory, holding the
# machine-hosts contract the machine root writes for an OrbStack machine.
setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/local"
  export TF_VAR_state_directory="$BATS_TEST_ROOT/state"
  mkdir -p "$TF_VAR_state_directory"
  cp "$k0s_root/tests/fixtures/machine-hosts.yaml" "$TF_VAR_state_directory/"
}

# Prints the planned attributes of one resource address.
planned() {
  local address="$1"
  shift
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$k0s_root" plan -input=false -out="$plan" "$@" >/dev/null
  tofu -chdir="$k0s_root" show -json "$plan" |
    jq --arg address "$address" '.resource_changes[] | select(.address == $address) | .change.after'
}

# Prints one planned output, with the names of values the plan cannot know
# yet mapped to true.
planned_output() {
  local name="$1" plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$k0s_root" plan -input=false -out="$plan" >/dev/null
  tofu -chdir="$k0s_root" show -json "$plan" |
    jq --arg name "$name" '.output_changes[$name] | (.after_unknown // {}) + (.after // {})'
}

# Prints the planned attributes of the rendered k0sctl configuration file.
k0sctl_file() {
  planned local_file.k0sctl "$@"
}

# Prints the k0s ClusterConfig inside the rendered k0sctl configuration, as YAML.
cluster_config() {
  k0sctl_file "$@" | jq -r '.content' | yq -r '.spec.k0s.config' -o yaml
}

# Applies the root against a fixture environment, keeping its state in
# $BATS_TEST_TMPDIR/allocations.tfstate, so a later plan against another
# fixture sees the allocation records this one wrote.
apply_environment() {
  TF_VAR_environment="$1" TF_VAR_environments_directory="$k0s_root/tests/fixtures/environments" \
    tofu -chdir="$k0s_root" apply -input=false -auto-approve -no-color -state="$BATS_TEST_TMPDIR/allocations.tfstate" >/dev/null
}

# Plans the root against a fixture environment and the state apply_environment kept.
plan_environment() {
  TF_VAR_environment="$1" TF_VAR_environments_directory="$k0s_root/tests/fixtures/environments" \
    tofu -chdir="$k0s_root" plan -input=false -no-color -state="$BATS_TEST_TMPDIR/allocations.tfstate"
}

# Writes the cluster-access contract the Kubernetes root writes when it is
# applied: the runtime values it plans, and the path of a kubeconfig for a
# cluster no test reaches.
cluster_access() {
  local state="$TF_VAR_state_directory" runtime_info
  cat >"$state/admin.kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters: [{name: test, cluster: {server: "https://127.0.0.1:1"}}]
users: [{name: test, user: {token: test}}]
contexts: [{name: test, context: {cluster: test, user: test}}]
current-context: test
KUBECONFIG
  runtime_info=$(planned_output runtime_info)
  jq -n --argjson runtime_info "$runtime_info" --arg kubeconfig "$state/admin.kubeconfig" \
    '{kubeconfig_path: $kubeconfig, runtime_info: $runtime_info}' | yq -P >"$state/cluster-access.yaml"
}

# Prints the values the bootstrap Job chart receives, as the bootstrap root
# plans them against the cluster-access contract.
bootstrap_values() {
  local plan="$BATS_TEST_ROOT/bootstrap.tfplan"
  cluster_access
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$bootstrap_root" plan \
    -input=false -refresh=false -out="$plan" >/dev/null
  TF_DATA_DIR="$BATS_FILE_TMPDIR/tofu-bootstrap" tofu -chdir="$bootstrap_root" show -json "$plan" |
    jq -r '.resource_changes[] | select(.address == "module.bootstrap_flux.helm_release.this") | .change.after.values[0]'
}
