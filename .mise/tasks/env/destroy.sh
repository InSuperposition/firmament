#!/usr/bin/env bash
#MISE description="Destroy a whole environment"
#MISE confirm="Destroy environment {{usage.environment}} and everything in it?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
# The bootstrap only holds in-cluster transport objects, which go with the
# machine. Forgetting them first lets destroy finish when the API server is
# already gone.
resources=$(tofu_in_environment "$environment" state list)
if grep -q '^module\.bootstrap_flux\.' <<<"$resources"; then
  # state rm writes its backup into the working directory unless told
  # otherwise; the state directory keeps it next to the state, out of Git.
  tofu_in_environment "$environment" state rm \
    -backup="$(state_directory "$environment")/terraform.tfstate.bootstrap.backup" \
    module.bootstrap_flux
fi
tofu_in_environment "$environment" destroy -input=false -auto-approve
