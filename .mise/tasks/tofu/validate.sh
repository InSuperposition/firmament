#!/usr/bin/env bash
#MISE description="Validate every environment and the modules it uses, without a backend"
set -euo pipefail

for directory in "${MISE_PROJECT_ROOT:?}"/environment/*/; do
  tofu -chdir="$directory" init -backend=false -input=false -reconfigure >/dev/null
  tofu -chdir="$directory" validate
done
