#!/usr/bin/env bash
#MISE description="Check Ubuntu readiness on the machine by planning the os-ubuntu module, which runs its probe over SSH"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

init_environment "$environment"
tofu_in_environment "$environment" plan -input=false -target=module.os_ubuntu
