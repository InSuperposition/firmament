#!/usr/bin/env bash
#MISE description="Rebuild the environment's cluster from scratch from the pushed branch and run every live check against it; destroys the cluster and leaves it destroyed (about 17 minutes)"
#MISE confirm="Destroy environment {{usage.environment}}, rebuild it for the end-to-end run, and leave it destroyed?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--from-ref <branch>" help="Also test an upgrade: build the cluster from this pushed branch first, then apply the checked-out branch over it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
from_branch="${usage_from_ref:-}"

#   [--from-ref: destroy > apply baseline > verify baseline >]
#   destroy > apply > verify > conformance > destroy
#
# Flux reads the branch from origin, so the run tests exactly the pushed
# commit: it refuses a checkout that differs from origin, and fails if
# origin moves while it runs. The first failing step stops the run and
# leaves the cluster as it is, so the failure can be inspected. The next
# run starts with a destroy.

# Runs one step, or stops the run and says how to clean up.
step() {
  if ! "$@"; then
    fail "env:e2e stopped at: $*"$'\n'"The cluster is left as it is. Remove it with: mise run --yes env:destroy $environment"
    exit 1
  fi
}

# Fails unless the checkout is clean, untracked files included, and HEAD is
# the tip of the branch on origin.
require_pushed_checkout() {
  local branch="$1" head tip
  if [[ -n "$(git -C "$MISE_PROJECT_ROOT" status --porcelain --untracked-files=all)" ]]; then
    fail "the working tree has changes Flux cannot see; commit and push them first"
    return
  fi
  tip=$(remote_branch_sha "$branch") || return
  head=$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)
  if [[ "$head" != "$tip" ]]; then
    fail "HEAD $head is not origin/$branch $tip; push or pull first"
  fi
}

# Fails when a branch on origin no longer points at the commit the run tested.
remote_tip_unchanged() {
  local branch="$1" tested="$2" tip
  git -C "$MISE_PROJECT_ROOT" fetch --quiet origin
  tip=$(remote_branch_sha "$branch") || return
  if [[ "$tip" != "$tested" ]]; then
    fail "origin/$branch moved from $tested to $tip during the run, so the cluster did not test one commit"
  fi
}

environment_directory "$environment" >/dev/null
branch=$(git_branch)
git -C "$MISE_PROJECT_ROOT" fetch --quiet origin
require_pushed_checkout "$branch"
tested=$(remote_branch_sha "$branch")

if [[ -n "$from_branch" ]]; then
  check_branch_name "$from_branch"
  baseline=$(remote_branch_sha "$from_branch")
  worktrees=$(mktemp -d)
  worktree="$worktrees/baseline"
  trap 'git -C "$MISE_PROJECT_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1; rm -rf "$worktrees"' EXIT
  git -C "$MISE_PROJECT_ROOT" worktree add --quiet --detach "$worktree" "$baseline"
  if [[ -d "$worktree/modules/cni-cilium" ]]; then
    fail "origin/$from_branch installs Cilium through k0s, which uninstalls it when Flux takes over; --from-ref needs a baseline where Flux already owns Cilium"
    exit 1
  fi
fi

step mise run --yes env:destroy "$environment"
if [[ -n "$from_branch" ]]; then
  # The baseline applies with its own configuration and tasks, against the
  # same state, and Flux follows the baseline branch until the switch.
  step env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH="$from_branch" MISE_TRUSTED_CONFIG_PATHS="$worktree" \
    mise --cd "$worktree" run env:apply "$environment"
  step env FIRMAMENT_GIT_BRANCH="$from_branch" mise run env:verify "$environment"
fi
step mise run env:apply "$environment"
step mise run verify "$environment"
step mise run cilium:conformance "$environment"
step remote_tip_unchanged "$branch" "$tested"
if [[ -n "$from_branch" ]]; then
  step remote_tip_unchanged "$from_branch" "$baseline"
fi
step mise run --yes env:destroy "$environment"
printf 'env:e2e passed for %s at %s; the cluster is destroyed.\n' "$environment" "$tested"
