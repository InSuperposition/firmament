#!/usr/bin/env bash
#MISE description="Run the Cilium connectivity suite against the cluster, checking only logs written during the tests (slow; deploys test workloads)"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
cilium --kubeconfig "$kubeconfig" connectivity test --log-check-only-test-time
