#!/usr/bin/env bash
#MISE description="Rebuild the environment's cluster from scratch from the pushed branch and run every live check against it; with --from-branch, also checks that traffic survives the switch; destroys the cluster and leaves it destroyed (about 17 minutes)"
#MISE confirm="Destroy environment {{usage.environment}}, rebuild it for the end-to-end run, and leave it destroyed?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
#USAGE flag "--from-branch <branch>" help="Also test an upgrade: build the cluster from this branch, already merged into origin/main, then apply the checked-out branch over it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"
from_branch="${usage_from_branch:-}"

#   destroy > [--from-branch: apply baseline > verify baseline > snapshot >
#   start traffic >] apply > verify > [--from-branch: compare snapshot >
#   check traffic >] conformance > destroy
#
# Flux reads the branch from origin, so the run tests exactly the pushed
# commit: it refuses a checkout that differs from origin, and fails if
# origin moves while it runs. The first failing step stops the run and
# leaves the cluster as it is, so the failure can be inspected. The next
# run starts with a destroy.
#
# An upgrade run keeps the workloads tests/upgrade-unaffected lists on the
# same pods and containers across the switch. Health is checked separately
# by verify. Traffic started before the switch must survive it:
# cilium:traffic-check fails on a broken connection or a failed request,
# and its last line, repeated in the final one here, says whether the
# traffic crossed a Cilium agent restart.

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
  local branch="$1" changes head tip
  changes=$(git -C "$MISE_PROJECT_ROOT" status --porcelain --untracked-files=all) || return
  if [[ -n "$changes" ]]; then
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
  git -C "$MISE_PROJECT_ROOT" fetch --quiet origin || return
  tip=$(remote_branch_sha "$branch") || return
  if [[ "$tip" != "$tested" ]]; then
    fail "origin/$branch moved from $tested to $tip during the run, so the cluster did not test one commit"
  fi
}

environment_directory "$environment" >/dev/null
# Every step, the baseline's included, runs as this checkout.
FIRMAMENT_WORKTREE=$(current_worktree)
export FIRMAMENT_WORKTREE
claim_environment "$environment"
branch=$(git_branch)
git -C "$MISE_PROJECT_ROOT" fetch --quiet origin
require_pushed_checkout "$branch"
tested=$(remote_branch_sha "$branch")

if [[ -n "$from_branch" ]]; then
  check_branch_name "$from_branch"
  if [[ "$from_branch" == "$branch" ]]; then
    fail "--from-branch names the checked-out branch $branch, so there is no upgrade to test"
    exit 1
  fi
  baseline=$(remote_branch_sha "$from_branch")
  main=$(remote_branch_sha main)
  # The baseline's own tasks and hooks run on this machine, so only commits
  # already merged into main qualify.
  if ! git -C "$MISE_PROJECT_ROOT" merge-base --is-ancestor "$baseline" "$main"; then
    fail "origin/$from_branch at $baseline is not merged into origin/main; --from-branch only runs baselines already on main"
    exit 1
  fi
  # k0s uninstalls a Cilium it installed once Flux takes it over, so the
  # baseline must already hand Cilium to Flux.
  if ! git -C "$MISE_PROJECT_ROOT" cat-file -e "$baseline:components/cni-cilium/helmrelease.yaml" 2>/dev/null; then
    fail "origin/$from_branch at $baseline does not hand Cilium to Flux (no components/cni-cilium/helmrelease.yaml); --from-branch needs a baseline where Flux owns Cilium"
    exit 1
  fi
  unaffected="$(environment_directory "$environment")/tests/upgrade-unaffected"
  [[ -f "$unaffected" ]] || fail "environment '$environment' lists no workloads an upgrade must leave running at $unaffected"
  printf 'Baseline: origin/%s at %s\n' "$from_branch" "$baseline"
  scratch=$(mktemp -d)
  worktree="$scratch/baseline"
  trap 'git -C "$MISE_PROJECT_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1; rm -rf "$scratch"' EXIT
  git -C "$MISE_PROJECT_ROOT" worktree add --quiet --detach "$worktree" "$baseline"
fi

# Records the pods and containers of the workloads the upgrade must not touch.
snapshot_workloads() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$environment") || return
  workload_identities "$kubeconfig" "$unaffected" >"$scratch/before"
}

# Fails when a workload the upgrade must not touch runs on other pods or
# containers, or restarted, than in the snapshot taken before the switch.
workloads_unchanged() {
  local kubeconfig after
  kubeconfig=$(environment_kubeconfig "$environment") || return
  after=$(workload_identities "$kubeconfig" "$unaffected") || return
  if [[ "$after" != "$(cat "$scratch/before")" ]]; then
    fail "the upgrade replaced or restarted workloads it should not touch:"$'\n'"$(diff "$scratch/before" <(printf '%s\n' "$after"))"
  fi
}

# Measures the traffic started before the switch, keeping its verdict line.
check_traffic() {
  mise run cilium:traffic-check "$environment" | tee "$scratch/traffic"
}

step mise run --yes env:destroy "$environment"
if [[ -n "$from_branch" ]]; then
  # The baseline applies and verifies with its own configuration, tasks and
  # cluster suite, against the same state, and Flux follows the baseline
  # branch until the switch.
  step env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH="$from_branch" MISE_TRUSTED_CONFIG_PATHS="$worktree" \
    mise --cd "$worktree" run env:apply "$environment"
  step platform_versions "$environment"
  step env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH="$from_branch" MISE_TRUSTED_CONFIG_PATHS="$worktree" \
    mise --cd "$worktree" run env:verify "$environment"
  step snapshot_workloads
  step mise run cilium:traffic-start "$environment"
fi
step mise run env:apply "$environment"
if [[ -z "$from_branch" ]]; then
  step platform_versions "$environment"
fi
step mise run verify "$environment"
if [[ -n "$from_branch" ]]; then
  step workloads_unchanged
  # Before conformance, whose cleanup removes the conn-disrupt workloads.
  step check_traffic
fi
step mise run cilium:conformance "$environment"
step remote_tip_unchanged "$branch" "$tested"
if [[ -n "$from_branch" ]]; then
  step remote_tip_unchanged "$from_branch" "$baseline"
fi
step mise run --yes env:destroy "$environment"
if [[ -n "$from_branch" ]]; then
  printf 'env:e2e passed for %s at %s: %s; the cluster is destroyed.\n' "$environment" "$tested" "$(tail -n 1 "$scratch/traffic")"
else
  printf 'env:e2e passed for %s at %s; the cluster is destroyed.\n' "$environment" "$tested"
fi
