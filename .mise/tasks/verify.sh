#!/usr/bin/env bash
#MISE description="Run every *:verify task against an environment, one at a time; --only keeps the environment's own checks and the chosen packages'"
#USAGE flag "--only <packages>" help="Comma-separated packages to check, such as cilium,flux; tasks that check the environment itself always run (default: every package)"
#USAGE flag "--changed" help="Choose the packages this branch changed since it left origin/main, instead of --only"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
require_environment >/dev/null

# One at a time: each task runs tofu init in the same environment directory.
# env:verify goes first: it waits for Flux to apply origin's tip, so the
# other tasks check what that commit deploys, not what ran before it.
only=$(package_selection "${usage_only:-}" "${usage_changed:-false}")
packages=$(deployed_packages)
deployed_names=" "
while IFS= read -r package; do
  [[ -n "$package" ]] && deployed_names+="${package##*/} "
done <<<"$packages"
verify_tasks=$(mise tasks ls --name-only | grep ':verify$')
mapfile -t tasks < <(
  grep -x 'env:verify' <<<"$verify_tasks" || true
  grep -vx 'env:verify' <<<"$verify_tasks" || true
)
for task in "${tasks[@]}"; do
  noun="${task%%:*}"
  # A task whose noun is a deployed package checks that package; any other
  # task checks the environment itself and always runs.
  if [[ "$deployed_names" == *" $noun "* ]] && ! package_selected "$noun" "$only"; then
    continue
  fi
  if [[ "$task" == env:verify && -n "$only" ]]; then
    mise run "$task" --only "$only"
  else
    mise run "$task"
  fi
done
