#!/usr/bin/env bash
#MISE description="Check every environment's chainsaw suite against the chainsaw schema and allow only read-only operations"
set -euo pipefail

# Prints one line per rule a suite breaks. A suite may only read the
# cluster: it runs in kube-system, which always exists, so chainsaw creates
# no namespace; its steps only assert or expect an error; and on failure it
# only collects diagnostics.
read_only_violations() {
  yq -r '
    (.spec | select(.namespace != "kube-system") | "spec.namespace must be kube-system, not " + (.namespace // "unset")),
    (.spec.steps[] | keys[] | select(. == "use" or . == "cleanup") | "step may not declare " + .),
    (.spec.steps[] | (.try // [])[] | keys[]
      | select(test("^(assert|error|description)$") | not) | "try may not run " + .),
    (.spec.steps[] | ((.catch // []) + (.finally // []))[] | keys[]
      | select(test("^(describe|events|get|podLogs|description)$") | not) | "catch and finally may not run " + .)
  ' "$1"
}

status=0
mapfile -t suites < <(find "${MISE_PROJECT_ROOT:?}/environment" -path '*/tests/cluster/*' -name chainsaw-test.yaml | sort)
for suite in "${suites[@]}"; do
  if ! schema=$(chainsaw lint test -f "$suite" 2>&1); then
    printf '%s: not a valid chainsaw test\n%s\n' "$suite" "$schema" >&2
    status=1
    continue
  fi
  violations=$(read_only_violations "$suite")
  if [[ -n "$violations" ]]; then
    while IFS= read -r violation; do
      printf '%s: %s\n' "$suite" "$violation" >&2
    done <<<"$violations"
    status=1
  fi
done
exit "$status"
