#!/usr/bin/env bash
#MISE description="Check each of the environment's machines is ready for k0s: Ubuntu 26.04, systemd, cgroup v2, kernel BTF, passwordless sudo, curl and systemctl"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

machines=$(environment_machines "$environment")
status=0
while read -r machine _; do
  [[ -n "$machine" ]] || continue
  check_ubuntu_ready "$machine" || status=1
done <<<"$machines"
exit "$status"
