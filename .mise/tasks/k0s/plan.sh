#!/usr/bin/env bash
#MISE description="Plan the Kubernetes root against the machine-hosts contract the machine root wrote"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

init_root kubernetes-k0s
tofu_in_root kubernetes-k0s plan -input=false
