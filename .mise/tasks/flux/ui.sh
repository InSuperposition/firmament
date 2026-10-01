#!/usr/bin/env bash
#MISE description="Open the Flux Web UI that Flux Operator serves in the browser through a port-forward; Ctrl-C stops it"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--port <port>" help="Local port the Flux Web UI port-forward listens on (default 9080)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
port="${usage_port:-9080}"

kubeconfig=$(environment_kubeconfig "$environment")
require_free_local_port "$port"
kubectl --kubeconfig "$kubeconfig" -n flux-system port-forward svc/flux-operator "$port:9080" >/dev/null &
forward=$!
trap 'kill "$forward" 2>/dev/null || true' EXIT
wait_for_local_port "$forward" "$port" 30
open "http://localhost:$port"
printf 'Flux Web UI on http://localhost:%s; Ctrl-C stops the port-forward\n' "$port"
wait "$forward"
