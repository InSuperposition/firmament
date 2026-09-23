#!/usr/bin/env bash
#MISE description="Run every OpenTofu test suite (tests/*.tftest.hcl) offline, without a backend"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

directories=$(tofu_test_directories)
while IFS= read -r directory; do
  [[ -n "$directory" ]] || continue
  init_offline "$directory"
  tofu -chdir="$directory" test
done <<<"$directories"
