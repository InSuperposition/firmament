#!/usr/bin/env bash
#MISE description="Wait for every node in the cluster to be Ready"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

kubeconfig=$(environment_kubeconfig)
kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
