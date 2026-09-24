#!/usr/bin/env bash
#MISE description="Rebuild the environment's cluster from scratch and run every live check against it; destroys the cluster and leaves it destroyed (about 17 minutes)"
#MISE confirm="Destroy environment {{usage.environment}}, rebuild it for the end-to-end run, and leave it destroyed?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

#   destroy > apply > verify > conformance > destroy
#
# The first failing step stops the run and leaves the cluster as it is, so
# the failure can be inspected. The next run starts with a destroy.

# Runs one step, or stops the run and says how to clean up.
step() {
  if ! "$@"; then
    fail "env:e2e stopped at: $*"$'\n'"The cluster is left as it is. Remove it with: mise run --yes env:destroy $environment"
    exit 1
  fi
}

environment_directory "$environment" >/dev/null

step mise run --yes env:destroy "$environment"
step mise run env:apply "$environment"
step mise run verify "$environment"
step mise run cilium:conformance "$environment"
step mise run --yes env:destroy "$environment"
printf 'env:e2e passed for %s; the cluster is destroyed.\n' "$environment"
