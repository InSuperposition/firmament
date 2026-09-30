# shellcheck shell=bash
# Running chainsaw suites against an environment's cluster.

# Prints the chainsaw suite directories an environment's cluster must pass,
# one per line: the environment's own tests/cluster first, then tests/cluster
# of each component its Flux build lists, for components that have one. A
# comma-separated module list keeps only those components' suites; the
# environment's own suite always runs.
cluster_suites() {
  local environment="$1" only="${2:-}" directory components component
  directory=$(environment_directory "$environment") || return
  check_modules "$environment" "$only" || return
  components=$(deployed_components "$environment") || return
  printf '%s\n' "$directory/tests/cluster"
  while IFS= read -r component; do
    if [[ -n "$component" && -d "$component/tests/cluster" ]] &&
      module_selected "$(module_name "$component")" "$only"; then
      printf '%s\n' "$component/tests/cluster"
    fi
  done <<<"$components"
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
