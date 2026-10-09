#!/usr/bin/env bash
#MISE description="Destroy an environment: the Kubernetes root, then the machine root"
#MISE confirm="Destroy environment {{usage.environment}} and everything in it?"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-openbao.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-openbao.sh"
require_environment >/dev/null

# Destroy never reads the branch Flux follows, so it also runs from a
# detached HEAD or an unusual branch name.
FIRMAMENT_GIT_BRANCH=$(git_branch 2>/dev/null) || FIRMAMENT_GIT_BRANCH=main
export FIRMAMENT_GIT_BRANCH

claim_environment
# The snapshot is what keeps OpenBao's root across the rebuild. Save it while
# OpenBao answers, and stop the destroy when the save fails; when the cluster
# cannot be reached, the snapshot from the last apply is the one kept.
if openbao_context 2>/dev/null && openbao_is_ready 2>/dev/null; then
  mise run openbao:snapshot
else
  printf 'warning: OpenBao is not reachable or not bound; the snapshot from the last apply is the one kept\n' >&2
fi
# The Kubernetes root goes first, then the machine; see
# destroy_environment_roots. The bootstrap root is left alone: its objects live
# in the cluster and go with the machine, and the next apply's refresh drops
# them from its state.
destroy_environment_roots
release_environment
