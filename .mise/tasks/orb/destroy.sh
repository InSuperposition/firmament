#!/usr/bin/env bash
#MISE description="Delete the OrbStack machine, and anything that depends on it"
#MISE confirm="Delete the OrbStack machine in {{usage.environment}} and everything that depends on it?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# Destroy never reads the branch Flux follows, so it also runs from a
# detached HEAD or an unusual branch name.
FIRMAMENT_GIT_BRANCH=$(git_branch 2>/dev/null) || FIRMAMENT_GIT_BRANCH=main
export FIRMAMENT_GIT_BRANCH

init_environment "$environment"
claim_environment "$environment"
# Destroying the machine takes the bootstrap, which depends on it, along.
forget_bootstrap "$environment"
tofu_in_environment "$environment" destroy -input=false -auto-approve -target=module.vm_orb
release_environment "$environment"
