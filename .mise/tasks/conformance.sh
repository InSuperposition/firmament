#!/usr/bin/env bash
#MISE description="Run every *:conformance task against an environment, one at a time; --only runs the tests the chosen modules need (slow; deploys test workloads)"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
#USAGE flag "--only <modules>" help="Comma-separated modules, such as cilium; each *:conformance task runs only the tests their tests/conformance files list (default: every test)"
#USAGE flag "--changed" help="Choose the modules this branch changed since it left origin/main, instead of --only"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# Every task gets --only: a suite can serve other modules than its own noun,
# as cilium:conformance runs the network tests a gateway module would need.
environment_directory "$environment" >/dev/null
only=$(module_selection "$environment" "${usage_only:-}" "${usage_changed:-false}")
if [[ "$only" == none ]]; then
  printf 'No modules changed, so no conformance tests run\n'
  exit 0
fi
mapfile -t tasks < <(mise tasks ls --name-only | grep ':conformance$' || true)
for task in "${tasks[@]}"; do
  if [[ -n "$only" ]]; then
    mise run "$task" "$environment" --only "$only"
  else
    mise run "$task" "$environment"
  fi
done
