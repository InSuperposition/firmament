#!/usr/bin/env bash
#MISE description="Destroy the cluster on the environment's OrbStack machines, then delete the machines environment.yaml lists"
#MISE confirm="Delete the OrbStack machines of {{usage.environment}} and everything on them?"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# Destroy never reads the branch Flux follows, so it also runs from a
# detached HEAD or an unusual branch name.
FIRMAMENT_GIT_BRANCH=$(git_branch 2>/dev/null) || FIRMAMENT_GIT_BRANCH=main
export FIRMAMENT_GIT_BRANCH

claim_environment "$environment"
destroy_environment "$environment"
