#!/usr/bin/env bash
#MISE description="Check every contract's YAML data against the #Contract its schema.cue defines, closed and offline; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# Each contract folder holds a schema.cue defining #Contract, and the YAML
# data #Contract closes over.
status=0
mapfile -t schemas < <(find "$MISE_PROJECT_ROOT/contracts" -mindepth 2 -maxdepth 2 -name schema.cue | sort)
if ((${#schemas[@]} == 0)); then
  fail "no contracts/*/schema.cue to check under $MISE_PROJECT_ROOT/contracts"
  exit 1
fi
for schema in "${schemas[@]}"; do
  directory=$(dirname -- "$schema")
  mapfile -t data < <(find "$directory" -maxdepth 1 -name '*.yaml' | sort)
  if ((${#data[@]} == 0)); then
    printf '%s: no YAML data beside the schema\n' "$directory" >&2
    status=1
    continue
  fi
  if ! cue vet -c -d '#Contract' "$schema" "${data[@]}"; then
    printf '%s: data does not match #Contract in schema.cue\n' "$directory" >&2
    status=1
  fi
done
exit "$status"
