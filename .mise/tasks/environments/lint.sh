#!/usr/bin/env bash
#MISE description="Fail when task code names an environment: a directory name under environments/ as a quoted string, an environments/<name> path or a <name> assignment in a non-comment line of a script under .mise/tasks; changes nothing"
set -euo pipefail

# The environment is selected by MISE_ENV and its paths come from mise.toml,
# so a task names none. A bare word is not checked: an environment named
# local would match the shell keyword.
root="${MISE_PROJECT_ROOT:?run this through mise}"
status=0
mapfile -t names < <(find "$root/environments" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
mapfile -t scripts < <(find "$root/.mise/tasks" -type f -name '*.sh' | sort)
for name in "${names[@]}"; do
  for script in "${scripts[@]}"; do
    matches=$(grep -nE "([\"']${name}[\"']|environments/${name}([^A-Za-z0-9-]|\$)|=${name}([^A-Za-z0-9-]|\$))" "$script" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [[ -n "$matches" ]]; then
      printf '%s: names environment %s:\n%s\n' "${script#"$root"/}" "$name" "$matches" >&2
      status=1
    fi
  done
done
exit "$status"
