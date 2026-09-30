#!/usr/bin/env bash
#MISE description="Check every machine environment.yaml lists runs with its limits: memory and CPUs from the machine's cgroup, disk from OrbStack"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

verify_machines "$environment"
