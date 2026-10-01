#!/usr/bin/env bash
#MISE description="Plan the Kubernetes root against the machine-hosts contract the machine root wrote"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_root "$environment" kubernetes-k0s
tofu_in_root "$environment" kubernetes-k0s plan -input=false
