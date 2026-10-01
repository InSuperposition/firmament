#!/usr/bin/env bash
#MISE description="Plan the machine root, then the Kubernetes root once a machine is recorded, then the bootstrap root once a cluster is recorded"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" machine-orb
tofu_in_root "$environment" machine-orb plan -input=false

# Each later root reads the contract file the one before it wrote when it
# was applied, so a fresh environment has nothing to plan them against yet.
if [[ -z "$(contract_field_or_empty "$environment" machine-hosts.yaml .name)" ]]; then
  printf 'No machine recorded yet, so k0s and the bootstrap are not planned; they are applied after the machine.\n'
  exit 0
fi
init_root "$environment" kubernetes-k0s
tofu_in_root "$environment" kubernetes-k0s plan -input=false

if [[ -z "$(contract_field_or_empty "$environment" cluster-access.yaml .kubeconfig_path)" ]]; then
  printf 'No cluster recorded yet, so the bootstrap is not planned; it is applied after the cluster.\n'
  exit 0
fi
init_root "$environment" bootstrap-flux
tofu_in_root "$environment" bootstrap-flux plan -input=false
