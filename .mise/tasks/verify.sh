#!/usr/bin/env bash
#MISE description="Run every *:verify task against an environment, one at a time"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# One at a time: each task runs tofu init in the same environment directory.
# env:verify goes first: it waits for Flux to apply origin's tip, so the
# other tasks check what that commit deploys, not what ran before it.
environment_directory "$environment" >/dev/null
verify_tasks=$(mise tasks ls --name-only | grep ':verify$')
mapfile -t tasks < <(
  grep -x 'env:verify' <<<"$verify_tasks" || true
  grep -vx 'env:verify' <<<"$verify_tasks" || true
)
for task in "${tasks[@]}"; do
  mise run "$task" "$environment"
done
