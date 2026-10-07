#!/usr/bin/env bash
#MISE description="Install the Git hooks and create the shared OpenTofu provider cache (mise install runs this)"
set -euo pipefail

hk install --mise
mkdir -p "${TF_PLUGIN_CACHE_DIR:?TF_PLUGIN_CACHE_DIR is unset; run this through mise}"
