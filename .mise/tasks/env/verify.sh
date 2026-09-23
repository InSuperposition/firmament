#!/usr/bin/env bash
#MISE description="Run the environment's read-only chainsaw suite (tests/cluster) against its cluster, expecting the kube-proxy mode recorded in state"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

suite="$(environment_directory "$environment")/tests/cluster"
if [[ ! -d "$suite" ]]; then
  fail "environment '$environment' has no cluster suite at $suite"
fi

init_environment "$environment"
kube_proxy_replacement=$(environment_output "$environment" kube_proxy_replacement)
if [[ "$kube_proxy_replacement" != true && "$kube_proxy_replacement" != false ]]; then
  fail "expected the kube_proxy_replacement output to be true or false, got '$kube_proxy_replacement'; apply the environment first"
fi

chainsaw_in_environment "$environment" test --test-dir "$suite" \
  --set "kubeProxyReplacement=$kube_proxy_replacement"
