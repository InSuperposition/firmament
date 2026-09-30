#!/usr/bin/env bash
#MISE description="Print the native metadata of the environment's OrbStack machines without changing them"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

machines=$(environment_machines "$environment")
while read -r machine _; do
  [[ -n "$machine" ]] || continue
  orb info "$machine" --format json
done <<<"$machines"
