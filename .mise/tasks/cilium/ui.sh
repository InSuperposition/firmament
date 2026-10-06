#!/usr/bin/env bash
#MISE description="Open the Hubble UI in the browser through a port-forward; Ctrl-C stops it"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
#USAGE flag "--port <port>" help="Local port the Hubble UI port-forward listens on (default 12000)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
port="${usage_port:-12000}"

kubeconfig=$(environment_kubeconfig "$environment")
require_free_local_port "$port"
cilium --kubeconfig "$kubeconfig" hubble ui --port-forward "$port"
