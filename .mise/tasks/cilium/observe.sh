#!/usr/bin/env bash
#MISE description="Follow Hubble flows from every node through a Hubble Relay port-forward on a random local port; Ctrl-C stops it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

kubeconfig=$(environment_kubeconfig)
# Port 0 lets hubble pick a free local port, so a busy port never stops it.
hubble observe --kubeconfig "$kubeconfig" --port-forward --port-forward-port 0 --follow
