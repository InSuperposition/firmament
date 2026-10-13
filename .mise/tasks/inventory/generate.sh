#!/usr/bin/env bash
#MISE description="Write the selected environment's inventory of namespaces, tenants and packages to inventory.json in its state directory; changes nothing else"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
environment=$(require_environment) || exit
state="${TF_VAR_state_directory:?}"

mkdir -p "$state"
output=$(mktemp "$state/inventory.XXXXXX")
trap 'rm -f -- "$output"' EXIT
export_inventory >"$output" || exit
mv -- "$output" "$state/inventory.json"
printf 'wrote %s\n' "$state/inventory.json"
