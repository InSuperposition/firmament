#!/usr/bin/env bash
#MISE description="Plan the machine root, then the Kubernetes root once a machine is recorded, then the bootstrap root once a cluster is recorded"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root machine-orb
tofu_in_root machine-orb plan -input=false

# Each later root reads the contract file the one before it wrote when it
# was applied, so a fresh environment has nothing to plan them against yet.
if [[ -z "$(contract_field_or_empty machine-hosts.yaml .name)" ]]; then
  printf 'No machine recorded yet, so k0s and the bootstrap are not planned; they are applied after the machine.\n'
  exit 0
fi
init_root kubernetes-k0s
tofu_in_root kubernetes-k0s plan -input=false

if [[ -z "$(contract_field_or_empty cluster-access.yaml .kubeconfig_path)" ]]; then
  printf 'No cluster recorded yet, so the bootstrap is not planned; it is applied after the cluster.\n'
  exit 0
fi
init_root bootstrap-flux
tofu_in_root bootstrap-flux plan -input=false
