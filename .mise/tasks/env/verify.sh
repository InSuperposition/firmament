#!/usr/bin/env bash
#MISE description="Run the environment's read-only chainsaw suite (tests/cluster) against its cluster"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

suite="$(environment_directory "$environment")/tests/cluster"
if [[ ! -d "$suite" ]]; then
  fail "environment '$environment' has no cluster suite at $suite"
fi

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
chainsaw_in_environment "$environment" test --test-dir "$suite" --set-string flux_revision="$revision"
