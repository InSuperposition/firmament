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

# Prints the branch of this repository that Flux follows: FIRMAMENT_GIT_BRANCH
# when the caller sets it, otherwise the checked-out branch. A detached HEAD
# names no branch, so it fails instead of guessing one.
git_branch() {
  if [[ -n "${FIRMAMENT_GIT_BRANCH:-}" ]]; then
    printf '%s\n' "$FIRMAMENT_GIT_BRANCH"
    return
  fi
  git -C "${MISE_PROJECT_ROOT:?run this through mise}" symbolic-ref --short -q HEAD ||
    fail "HEAD is detached; set FIRMAMENT_GIT_BRANCH to the branch Flux should follow"
}

# Runs tofu in an environment's root, telling it where its state directory
# is and which branch Flux follows. Every other input belongs to the
# environment's own configuration.
tofu_in_environment() {
  local environment="$1"
  shift
  local directory state branch
  directory=$(environment_directory "$environment") || return
  state=$(state_directory "$environment") || return
  branch=$(git_branch) || return
  TF_VAR_state_directory="$state" TF_VAR_git_branch="$branch" tofu -chdir="$directory" "$@"
}

# Points an environment's OpenTofu backend at its state file. Providers
# install only as the committed lock file records them.
init_environment() {
  local environment="$1"
  local state
  environment_directory "$environment" >/dev/null || return
  state=$(state_directory "$environment") || return
  mkdir -p "$state"
  tofu_in_environment "$environment" init -input=false -reconfigure -lockfile=readonly \
    -backend-config="path=$state/terraform.tfstate" >/dev/null
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
  for suite in "${MISE_PROJECT_ROOT:?run this through mise}"/{modules,environment}/*/tests/*.tftest.hcl; do
    if [[ -e "$suite" ]]; then
      dirname -- "$(dirname -- "$suite")"
    fi
  done | sort -u
}

# Prints one output from an environment's state.
environment_output() {
  tofu_in_environment "$1" output -raw "$2"
}

# Prints the kubeconfig path recorded in an environment's state.
environment_kubeconfig() {
  environment_output "$1" kubeconfig_path
}

# Runs chainsaw against an environment's cluster. chainsaw has no kubeconfig
# flag; it reads KUBECONFIG, set here from the path recorded in state.
chainsaw_in_environment() {
  local environment="$1"
  shift
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$environment") || return
  KUBECONFIG="$kubeconfig" chainsaw "$@"
}

# Waits until the node the cluster just created has registered with the API
# server. Retries while k0s starts the API server, whereas kubectl wait fails
# on a node that does not exist yet.
wait_for_node() {
  local kubeconfig="$1" timeout="${2:-300}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout))
  until [[ -n "$(kubectl --kubeconfig "$kubeconfig" get nodes -o name 2>/dev/null)" ]]; do
    if ((SECONDS >= deadline)); then
      fail "no node registered with the API server within ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
}

# Waits until the cluster runs what was just applied. The first Cilium wait
# retries while k0s restarts the API server after apply, whereas kubectl
# fails on the first refused connection. Flux then reports its own
# reconcile and the Cilium release, and Cilium is checked again on the pods
# an upgrade rolled out.
wait_for_cluster() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$1") || return
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=10m
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready helmrelease/cilium --timeout=10m
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
}
