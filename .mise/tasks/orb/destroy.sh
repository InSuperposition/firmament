#!/usr/bin/env bash
#MISE description="Delete the OrbStack machine and the k0s cluster on it (the Kubernetes root, then the machine root); Flux's objects go with it"
#MISE confirm="Delete the OrbStack machine in {{usage.environment}} and everything that depends on it?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# Destroy never reads the branch Flux follows, so it also runs from a
# detached HEAD or an unusual branch name.
FIRMAMENT_GIT_BRANCH=$(git_branch 2>/dev/null) || FIRMAMENT_GIT_BRANCH=main
export FIRMAMENT_GIT_BRANCH

environment_directory "$environment" >/dev/null
claim_environment "$environment"
state=$(state_directory "$environment")
# k0s cannot outlive its machine, so the Kubernetes root goes first: a k0s
# record left pointing at a deleted machine would make the next apply skip
# installing k0s on the new one. The bootstrap root is left alone: its
# objects go with the machine, and the next apply's refresh drops them. A
# root with no state file has nothing to destroy.
for root in kubernetes-k0s machine-orb; do
  [[ -f "$state/$root.tfstate" ]] || continue
  init_root "$environment" "$root"
  tofu_in_root "$environment" "$root" destroy -input=false -auto-approve
done
release_environment "$environment"
