#!/usr/bin/env bash
#MISE description="Run the read-only chainsaw suites against the environment's cluster: its cluster definition's tests/cluster, then tests/cluster of each package its Flux build deploys"
#USAGE flag "--only <packages>" help="Comma-separated packages whose suites run, such as cilium,flux; the environment's own suite always runs (default: every package)"
#USAGE flag "--changed" help="Choose the packages this branch changed since it left origin/main, instead of --only"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment=$(require_environment)

suite="$(cluster_directory)/tests/cluster"
if [[ ! -d "$suite" ]]; then
  fail "environment '$environment' runs a cluster with no suite at $suite"
fi
only=$(package_selection "${usage_only:-}" "${usage_changed:-false}")

# The suite checks that Flux applied the checked-out branch at the tip
# origin had when last fetched. Flux polls Git on its own interval, so the
# task first waits for that revision instead of racing it.
branch=$(git_branch)
git -C "$MISE_PROJECT_ROOT" fetch --quiet origin
revision=$(flux_revision "$branch")

kubeconfig=$(environment_kubeconfig)
kubectl --kubeconfig "$kubeconfig" -n flux-system wait kustomization/flux-system \
  --for=jsonpath='{.status.lastAppliedRevision}'="$revision" --timeout=10m
suites=$(cluster_suites "$only")
# The suites check the cluster against the values OpenTofu gave Flux.
values_file=$(mktemp)
trap 'rm -f "$values_file"' EXIT
contract_field cluster-access.yaml .runtime_info >"$values_file"
test_directories=()
while IFS= read -r directory; do
  test_directories+=(--test-dir "$directory")
done <<<"$suites"
chainsaw_in_environment test "${test_directories[@]}" --values "$values_file" \
  --set-string flux_revision="$revision"
