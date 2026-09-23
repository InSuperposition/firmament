# shellcheck shell=bash
# Helpers shared by the mise file tasks in .mise/tasks. Source this file;
# it defines functions only and changes no state when sourced.

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# Prints the OpenTofu root directory of an environment, or fails when the
# environment does not exist.
environment_directory() {
  local environment="$1"
  local directory="${MISE_PROJECT_ROOT:?run this through mise}/environment/$environment"
  if [[ ! -d "$directory" ]]; then
    fail "unknown environment '$environment': $directory does not exist"
    return
  fi
  printf '%s\n' "$directory"
}

# Prints where an environment keeps its state and kubeconfig. mise sets
# FIRMAMENT_STATE_HOME from mise.toml [env].
state_directory() {
  printf '%s/environment/%s\n' "${FIRMAMENT_STATE_HOME:?FIRMAMENT_STATE_HOME is unset; run this through mise}" "$1"
}

# Runs tofu in an environment's root with the variables every environment
# takes from the machine rather than from Git.
tofu_in_environment() {
  local environment="$1"
  shift
  local directory state
  directory=$(environment_directory "$environment") || return
  state=$(state_directory "$environment") || return
  TF_VAR_state_directory="$state" \
    TF_VAR_orbstack_ssh_key_path="${FIRMAMENT_ORBSTACK_SSH_KEY:-$HOME/.orbstack/ssh/id_ed25519}" \
    tofu -chdir="$directory" "$@"
}

# Points an environment's OpenTofu backend at its state file.
init_environment() {
  local environment="$1"
  local state
  state=$(state_directory "$environment") || return
  mkdir -p "$state"
  tofu_in_environment "$environment" init -input=false -reconfigure \
    -backend-config="path=$state/terraform.tfstate" >/dev/null
}

# Prints the kubeconfig path recorded in an environment's state.
environment_kubeconfig() {
  tofu_in_environment "$1" output -raw kubeconfig_path
}

# Waits until the cluster and Cilium are healthy after an apply. Cilium goes
# first: it retries while k0s restarts the API server after apply, whereas
# kubectl wait fails on the first refused connection.
wait_for_cluster() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$1") || return
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
}
