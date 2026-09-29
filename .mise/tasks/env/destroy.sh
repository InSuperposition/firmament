#!/usr/bin/env bash
#MISE description="Destroy a whole environment"
#MISE confirm="Destroy environment {{usage.environment}} and everything in it?"
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
# The bootstrap root is left alone: its objects live in the cluster and go
# with the machine, and the next apply's refresh drops them from its state.
tofu_in_environment "$environment" destroy -input=false -auto-approve
release_environment "$environment"
