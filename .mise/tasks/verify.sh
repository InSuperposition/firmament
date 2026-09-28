#!/usr/bin/env bash
#MISE description="Run every *:verify task against an environment, one at a time; --only keeps the environment's own checks and the chosen modules'"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--only <modules>" help="Comma-separated modules to check, such as cilium,flux; tasks that check the environment itself always run (default: every module)"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
only="${usage_only:-}"

# One at a time: each task runs tofu init in the same environment directory.
# env:verify goes first: it waits for Flux to apply origin's tip, so the
# other tasks check what that commit deploys, not what ran before it.
environment_directory "$environment" >/dev/null
check_modules "$environment" "$only"
components=$(deployed_components "$environment")
modules=" "
while IFS= read -r component; do
  [[ -n "$component" ]] && modules+="$(module_name "$component") "
done <<<"$components"
verify_tasks=$(mise tasks ls --name-only | grep ':verify$')
mapfile -t tasks < <(
  grep -x 'env:verify' <<<"$verify_tasks" || true
  grep -vx 'env:verify' <<<"$verify_tasks" || true
)
for task in "${tasks[@]}"; do
  noun="${task%%:*}"
  # A task whose noun is a deployed module checks that module; any other
  # task checks the environment itself and always runs.
  if [[ "$modules" == *" $noun "* ]] && ! module_selected "$noun" "$only"; then
    continue
  fi
  if [[ "$task" == env:verify && -n "$only" ]]; then
    mise run "$task" "$environment" --only "$only"
  else
    mise run "$task" "$environment"
  fi
done
