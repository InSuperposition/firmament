#!/usr/bin/env bash
#MISE description="Check every tracked contract's YAML data against the #Contract its schema.cue defines, closed and offline; changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

# Each contract folder holds a schema.cue defining #Contract, and the YAML
# data #Contract closes over. Only files git lists (tracked, or added to
# the index) are checked, as they are on disk: a modified file is checked
# unstaged, and an untracked file is named and skipped.
cd "$MISE_PROJECT_ROOT"
status=0

while IFS= read -r untracked; do
  printf '%s: untracked, not checked\n' "$untracked" >&2
done < <(git ls-files --others --exclude-standard -- contracts)

mapfile -t tracked < <(git ls-files -- contracts)
mapfile -t schemas < <(printf '%s\n' "${tracked[@]}" | grep -E '^contracts/[^/]+/schema\.cue$' | sort || true)
if ((${#schemas[@]} == 0)); then
  fail "no contracts/*/schema.cue to check under $MISE_PROJECT_ROOT/contracts"
  exit 1
fi
for schema in "${schemas[@]}"; do
  directory=$(dirname -- "$schema")
  mapfile -t data < <(printf '%s\n' "${tracked[@]}" | grep -E "^${directory}/[^/]+\.yaml\$" | sort || true)
  existing=()
  for file in "${data[@]}"; do
    [[ -f "$file" ]] && existing+=("$file")
  done
  if ((${#existing[@]} == 0)); then
    printf '%s: no YAML data beside the schema\n' "$directory" >&2
    status=1
    continue
  fi
  if ! cue vet -c -d '#Contract' "$schema" "${existing[@]}"; then
    printf '%s: data does not match #Contract in schema.cue\n' "$directory" >&2
    status=1
  fi
done
exit "$status"
