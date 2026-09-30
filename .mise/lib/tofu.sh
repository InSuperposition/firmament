# shellcheck shell=bash
# Running OpenTofu in an environment's roots and reading their outputs.

# Runs tofu in an OpenTofu directory of an environment, telling it where the
# environment's state directory is and which branch Flux follows. Every other
# input belongs to the directory's own configuration.
tofu_in_directory() {
  local environment="$1" directory="$2"
  shift 2
  local state branch
  state=$(state_directory "$environment") || return
  branch=$(git_branch) || return
  TF_VAR_state_directory="$state" TF_VAR_git_branch="$branch" tofu -chdir="$directory" "$@"
}

# Runs tofu in an environment's root, which owns the machine, its OS and
# k0s, and writes the kubeconfig and the runtime values.
tofu_in_environment() {
  local environment="$1" directory
  shift
  directory=$(environment_directory "$environment") || return
  tofu_in_directory "$environment" "$directory" "$@"
}

# Runs tofu in an environment's bootstrap root, which installs Cilium and
# Flux into the cluster the environment root created. Its state lives next
# to the environment's and outlives a destroy: the objects it records die
# with the machine, and the next apply's refresh drops them.
tofu_in_bootstrap() {
  local environment="$1" directory
  shift
  directory=$(environment_directory "$environment") || return
  tofu_in_directory "$environment" "$directory/bootstrap" "$@"
}

# Points an environment's OpenTofu backend at its state file. Providers
# install only as the committed lock file records them.
init_environment() {
  local environment="$1"
  local state
  environment_directory "$environment" >/dev/null || return
  move_legacy_state_directory "$environment" || return
  state=$(state_directory "$environment") || return
  refuse_empty_state "$state/terraform.tfstate" || return
  mkdir -p "$state"
  move_bootstrap_state "$state" || return
  forget_machine_state "$state" || return
  tofu_in_environment "$environment" init -input=false -reconfigure -lockfile=readonly \
    -backend-config="path=$state/terraform.tfstate" >/dev/null
}

# Points an environment's bootstrap root at its own state file, next to the
# environment's.
init_bootstrap() {
  local environment="$1"
  local state
  state=$(state_directory "$environment") || return
  refuse_empty_state "$state/bootstrap.tfstate" || return
  tofu_in_bootstrap "$environment" init -input=false -reconfigure -lockfile=readonly \
    -backend-config="path=$state/bootstrap.tfstate" >/dev/null
}

# Initializes an OpenTofu root or module without a backend, for checks that
# never read or write state. Providers install only as the committed lock
# file records them.
init_offline() {
  tofu -chdir="$1" init -backend=false -input=false -reconfigure -lockfile=readonly >/dev/null
}

# Prints each module or environment directory that holds an OpenTofu test
# suite (tests/*.tftest.hcl), once, in sorted order.
tofu_test_directories() {
  local suite
  for suite in "${MISE_PROJECT_ROOT:?run this through mise}"/{modules,environments}/*/tests/*.tftest.hcl; do
    if [[ -e "$suite" ]]; then
      dirname -- "$(dirname -- "$suite")"
    fi
  done | sort -u
}

# Prints one output from an environment's state, or nothing when the state
# has no value for it, as after a destroy. Fails only when the state cannot
# be read. It reads the JSON form: with no outputs, `tofu output -raw` prints
# a warning to stdout and still exits 0, while the JSON form prints an empty
# object.
environment_output_or_empty() {
  local outputs
  outputs=$(tofu_in_environment "$1" output -json) || return
  jq -r --arg name "$2" '.[$name].value // empty' <<<"$outputs"
}

# Prints one output from an environment's state. Fails when the state has no
# value for it, as after a destroy, or cannot be read.
environment_output() {
  local value
  value=$(environment_output_or_empty "$1" "$2") || return
  if [[ -z "$value" ]]; then
    fail "environment '$1' has no $2 in its state; apply it first"
    return
  fi
  printf '%s' "$value"
}

# Prints the kubeconfig path recorded in an environment's state.
environment_kubeconfig() {
  environment_output "$1" kubeconfig_path
}
