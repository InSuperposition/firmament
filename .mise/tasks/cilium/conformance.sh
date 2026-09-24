#!/usr/bin/env bash
#MISE description="Run the Cilium connectivity suite against the cluster, with Hubble flow validation and checking only logs written during the tests, then remove its test workloads (slow; deploys test workloads)"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--hubble-port <port>" help="Local port the Hubble Relay port-forward listens on (default 4245)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
hubble_port="${usage_hubble_port:-4245}"

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
# The suite reaches Hubble Relay only on a local address and opens no
# port-forward itself. Without one it disables flow validation and still
# passes, so the forward must be listening before the suite starts.
cilium --kubeconfig "$kubeconfig" hubble port-forward --port-forward "$hubble_port" >/dev/null &
relay_forward=$!
trap 'kill "$relay_forward" 2>/dev/null || true' EXIT
wait_for_local_port "$relay_forward" "$hubble_port" 60
cilium --kubeconfig "$kubeconfig" connectivity test --log-check-only-test-time \
  --hubble-server "localhost:$hubble_port" --flow-validation strict
# Reached only when the suite passed: a failed run keeps its test
# namespaces and pods for debugging.
cilium --kubeconfig "$kubeconfig" connectivity test --cleanup
