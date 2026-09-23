#!/usr/bin/env bash
#MISE description="Install the Git hooks and trust each environment's mise config (mise install runs this)"
set -euo pipefail

hk install --mise
for config in "${MISE_PROJECT_ROOT:?}"/environment/*/mise.toml; do
  mise trust --quiet "$config"
done
