#!/usr/bin/env bash
#MISE description="Create the OrbStack machines environment.yaml lists that do not exist, check each new one is ready for k0s, and write machine-hosts to the state directory; fails when an existing machine's limits differ"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

claim_environment "$environment"
apply_machines "$environment"
cat "$(state_directory "$environment")/machine-hosts.yaml"
