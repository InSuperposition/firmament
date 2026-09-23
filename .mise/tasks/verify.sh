#!/usr/bin/env bash
#MISE description="Run every *:verify task against an environment, one at a time"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# One at a time: each task runs tofu init in the same environment directory.
environment_directory "$environment" >/dev/null
mapfile -t tasks < <(mise tasks ls --name-only | grep ':verify$')
for task in "${tasks[@]}"; do
  mise run "$task" "$environment"
done
