#!/usr/bin/env bash
#MISE description="Follow Hubble flows from every node through a Hubble Relay port-forward on a random local port; Ctrl-C stops it"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
# Port 0 lets hubble pick a free local port, so a busy port never stops it.
hubble observe --kubeconfig "$kubeconfig" --port-forward --port-forward-port 0 --follow
