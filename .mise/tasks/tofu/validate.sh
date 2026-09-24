#!/usr/bin/env bash
#MISE description="Validate every environment and the modules it uses, without a backend"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

for directory in "${MISE_PROJECT_ROOT:?}"/environment/*/; do
  init_offline "$directory"
  tofu -chdir="$directory" validate
done
