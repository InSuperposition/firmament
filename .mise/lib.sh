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

# Runs tofu in an environment's root, telling it where its state directory
# is. Every other input belongs to the environment's own configuration.
tofu_in_environment() {
  local environment="$1"
  shift
  local directory state
  directory=$(environment_directory "$environment") || return
  state=$(state_directory "$environment") || return
  TF_VAR_state_directory="$state" tofu -chdir="$directory" "$@"
}

# Points an environment's OpenTofu backend at its state file.
init_environment() {
  local environment="$1"
  local state
  environment_directory "$environment" >/dev/null || return
  state=$(state_directory "$environment") || return
  mkdir -p "$state"
  tofu_in_environment "$environment" init -input=false -reconfigure \
    -backend-config="path=$state/terraform.tfstate" >/dev/null
}

# Initializes an OpenTofu root or module without a backend, for checks that
# never read or write state.
init_offline() {
  tofu -chdir="$1" init -backend=false -input=false -reconfigure >/dev/null
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

# Prints one "<state> <chart>" line per k0s Helm chart, where state is:
#   ready    k0s installed the current spec;
#   pending  k0s has not yet reconciled the current spec;
#   failed   k0s tried the current spec and recorded an error.
# k0s stores sha256(release name + values) of the spec it last reconciled in
# .status.valuesHash, whether or not that attempt failed, so comparing it with
# the current spec tells a pending upgrade from a finished one.
chart_states() {
  local charts rows name hash payload version_matches error expected
  charts=$(kubectl --kubeconfig "$1" -n kube-system get charts.helm.k0sproject.io -o json) || return
  rows=$(jq -r '.items[] | [
      .metadata.name,
      (.status.valuesHash // "-"),
      (((.spec.releaseName // .metadata.name) + (.spec.values // "")) | @base64),
      ((.status.version // "") == .spec.version),
      (.status.error // "")
    ] | @tsv' <<<"$charts") || return
  [[ -n "$rows" ]] || return 0
  while IFS=$'\t' read -r name hash payload version_matches error; do
    expected=$(printf '%s' "$payload" | base64 --decode | shasum -a 256)
    expected=${expected%% *}
    if [[ "$hash" != "$expected" ]]; then
      printf 'pending %s\n' "$name"
    elif [[ -n "$error" ]]; then
      printf 'failed %s\n' "$name"
    elif [[ "$version_matches" != true ]]; then
      printf 'pending %s\n' "$name"
    else
      printf 'ready %s\n' "$name"
    fi
  done <<<"$rows"
}

# Waits until every k0s Helm chart runs its current spec. Fails as soon as
# k0s records an error for the current spec, or when the timeout (seconds)
# passes, printing the charts so the Helm error is visible.
wait_for_charts() {
  local kubeconfig="$1" timeout="${2:-600}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout)) states
  while true; do
    if states=$(chart_states "$kubeconfig"); then
      if grep -q '^failed ' <<<"$states"; then
        fail "k0s could not install a Helm chart:"$'\n'"$states"
        kubectl --kubeconfig "$kubeconfig" -n kube-system get charts.helm.k0sproject.io -o yaml >&2
        return 1
      fi
      grep -q '^pending ' <<<"$states" || return 0
    fi
    if ((SECONDS >= deadline)); then
      fail "k0s did not reconcile the Helm charts within ${timeout}s:"$'\n'"${states:-charts unavailable}"
      kubectl --kubeconfig "$kubeconfig" -n kube-system get charts.helm.k0sproject.io -o yaml >&2
      return 1
    fi
    sleep "$interval"
  done
}

# Waits until the cluster runs what was just applied. The first Cilium wait
# retries while k0s restarts the API server after apply, whereas kubectl
# fails on the first refused connection. That wait can pass on the old pods
# while k0s upgrades the chart in the background, so the chart wait follows,
# then Cilium is checked again on the pods the upgrade rolled out.
wait_for_cluster() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$1") || return
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  wait_for_charts "$kubeconfig"
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
}
