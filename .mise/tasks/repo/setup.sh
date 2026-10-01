#!/usr/bin/env bash
#MISE description="Install the Git hooks, create the shared OpenTofu provider cache and trust each environment's mise config (mise install runs this)"
set -euo pipefail

hk install --mise
mkdir -p "${TF_PLUGIN_CACHE_DIR:?TF_PLUGIN_CACHE_DIR is unset; run this through mise}"
for config in "${MISE_PROJECT_ROOT:?}"/environments/*/mise.toml; do
  mise trust --quiet "$config"
done
