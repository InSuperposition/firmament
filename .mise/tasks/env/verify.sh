#!/usr/bin/env bash
#MISE description="Run the read-only chainsaw suites against the environment's cluster: its own tests/cluster, then tests/cluster of each component its Flux build deploys"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--only <modules>" help="Comma-separated modules whose suites run, such as cilium,flux; the environment's own suite always runs (default: every module)"
#USAGE flag "--changed" help="Choose the modules this branch changed since it left origin/main, instead of --only"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

suite="$(environment_directory "$environment")/tests/cluster"
if [[ ! -d "$suite" ]]; then
  fail "environment '$environment' has no cluster suite at $suite"
fi
only=$(module_selection "$environment" "${usage_only:-}" "${usage_changed:-false}")

# The suite checks that Flux applied the checked-out branch at the tip
# origin had when last fetched. Flux polls Git on its own interval, so the
# task first waits for that revision instead of racing it.
branch=$(git_branch)
git -C "$MISE_PROJECT_ROOT" fetch --quiet origin
revision=$(flux_revision "$branch")

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
kubectl --kubeconfig "$kubeconfig" -n flux-system wait kustomization/flux-system \
  --for=jsonpath='{.status.lastAppliedRevision}'="$revision" --timeout=10m
suites=$(cluster_suites "$environment" "$only")
# The suites check the cluster against the values OpenTofu gave Flux.
values_file=$(mktemp)
trap 'rm -f "$values_file"' EXIT
environment_output "$environment" runtime_info >"$values_file"
test_directories=()
while IFS= read -r directory; do
  test_directories+=(--test-dir "$directory")
done <<<"$suites"
chainsaw_in_environment "$environment" test "${test_directories[@]}" --values "$values_file" \
  --set-string flux_revision="$revision"
