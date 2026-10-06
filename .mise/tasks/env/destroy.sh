#!/usr/bin/env bash
#MISE description="Destroy an environment: the Kubernetes root, then the machine root"
#MISE confirm="Destroy environment {{usage.environment}} and everything in it?"
#USAGE arg "[environment]" default="local" help="Directory name under environments/"
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
# The Kubernetes root goes first: it reads the machine-hosts contract, which
# the machine root deletes. Destroying it resets nothing over SSH (k0s goes
# with the machine) and deletes the kubeconfig and the cluster-access
# contract. The bootstrap root is left alone: its objects live in the
# cluster and go with the machine, and the next apply's refresh drops them
# from its state. A root with no state file has nothing to destroy.
for root in kubernetes-k0s machine-orb; do
  [[ -f "$state/$root.tfstate" ]] || continue
  init_root "$environment" "$root"
  tofu_in_root "$environment" "$root" destroy -input=false -auto-approve
done
release_environment "$environment"
