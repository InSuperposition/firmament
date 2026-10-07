#!/usr/bin/env bash
#MISE description="Rebuild the environment's cluster from scratch from the pushed branch and run every live check against it; with --from-branch, also checks that traffic survives the switch; destroys the cluster and leaves it destroyed"
#MISE confirm="Destroy environment {{usage.environment}}, rebuild it for the end-to-end run, and leave it destroyed?"
#USAGE flag "--from-branch <branch>" help="Also test an upgrade: build the cluster from this branch, already merged into origin/main, then apply the checked-out branch over it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment=$(require_environment)
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
# cilium:traffic-check fails on a broken connection, a failed request or a
# rate under 90% of the one requested, and its last line, repeated in the
# final one here, says whether the traffic crossed a Cilium agent restart.

# Runs one step, or stops the run and says how to clean up. Records how long
# each passing step took, under its label; a label seen before in the run
# gets its ordinal, such as "env:destroy (2)".
step_times=""
step_labels=""
step() {
  local started=$SECONDS label count
  if ! "$@"; then
    fail "env:e2e stopped at: $*"$'\n'"The cluster is left as it is. Remove it with: mise run --yes env:destroy"
    exit 1
  fi
  label=$(step_label "$@")
  count=$(grep -cxF -- "$label" <<<"$step_labels" || true)
  step_labels+="$label"$'\n'
  if ((count > 0)); then
    label="$label ($((count + 1)))"
  fi
  step_times+="$label"$'\t'"$((SECONDS - started))"$'\n'
}

# Prints the time of each step and the change since the last passing run of
# the same kind, then keeps these times for the next run to compare with.
# Timings are only reported, never judged: image pulls and the host make
# them vary from run to run.
report_step_times() {
  local kept current
  kept="$TF_VAR_state_directory/e2e-step-times${from_branch:+-upgrade}"
  current=$(mktemp)
  printf '%s' "$step_times" >"$current"
  printf 'Step times (change since the last passing run):\n'
  step_time_report "$kept" "$current"
  mkdir -p "$(dirname "$kept")"
  mv "$current" "$kept"
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

# Every step, the baseline's included, runs as this checkout.
FIRMAMENT_WORKTREE=$(current_worktree)
export FIRMAMENT_WORKTREE
claim_environment
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
  if ! git -C "$MISE_PROJECT_ROOT" cat-file -e "$baseline:packages/cilium/helmrelease.yaml" 2>/dev/null; then
    fail "origin/$from_branch at $baseline does not hand Cilium to Flux (no packages/cilium/helmrelease.yaml); --from-branch needs a baseline where Flux owns Cilium"
    exit 1
  fi
  # The baseline's tasks run against the same state as this checkout's, so
  # they must derive the state directory from MISE_ENV the same way.
  if ! git -C "$MISE_PROJECT_ROOT" cat-file blob "$baseline:mise.toml" 2>/dev/null | grep -q '^TF_VAR_state_directory'; then
    fail "origin/$from_branch at $baseline does not derive the state directory from MISE_ENV (no TF_VAR_state_directory in its mise.toml); --from-branch needs a baseline that does"
    exit 1
  fi
  unaffected="$(environment_directory)/tests/upgrade-unaffected"
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
  kubeconfig=$(environment_kubeconfig) || return
  workload_identities "$kubeconfig" "$unaffected" >"$scratch/before"
}

# Fails when a workload the upgrade must not touch runs on other pods or
# containers, or restarted, than in the snapshot taken before the switch.
workloads_unchanged() {
  local kubeconfig after
  kubeconfig=$(environment_kubeconfig) || return
  after=$(workload_identities "$kubeconfig" "$unaffected") || return
  if [[ "$after" != "$(cat "$scratch/before")" ]]; then
    fail "the upgrade replaced or restarted workloads it should not touch:"$'\n'"$(diff "$scratch/before" <(printf '%s\n' "$after"))"
  fi
}

# Measures the traffic started before the switch, keeping its verdict line.
check_traffic() {
  mise run cilium:traffic-check | tee "$scratch/traffic"
}

step mise run --yes env:destroy
if [[ -n "$from_branch" ]]; then
  # The baseline applies and verifies with its own configuration, tasks and
  # cluster suite, against the same state, and Flux follows the baseline
  # branch until the switch.
  step env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH="$from_branch" MISE_TRUSTED_CONFIG_PATHS="$worktree" \
    mise --cd "$worktree" run env:apply
  step platform_versions
  step env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH="$from_branch" MISE_TRUSTED_CONFIG_PATHS="$worktree" \
    mise --cd "$worktree" run env:verify
  step snapshot_workloads
  step mise run cilium:traffic-start
fi
step mise run env:apply
if [[ -z "$from_branch" ]]; then
  step platform_versions
fi
step mise run verify
if [[ -n "$from_branch" ]]; then
  step workloads_unchanged
  # An upgrade that leaves the agent alone would leave the traffic check with
  # nothing to prove, so the agent restarts here, after the workloads check
  # and while the traffic runs.
  step mise run cilium:restart-agent
  # Before conformance, whose cleanup removes the conn-disrupt workloads.
  step check_traffic
fi
step mise run cilium:conformance
step remote_tip_unchanged "$branch" "$tested"
if [[ -n "$from_branch" ]]; then
  step remote_tip_unchanged "$from_branch" "$baseline"
fi
step mise run --yes env:destroy
report_step_times
if [[ -n "$from_branch" ]]; then
  printf 'env:e2e passed for %s at %s: %s; the cluster is destroyed.\n' "$environment" "$tested" "$(tail -n 1 "$scratch/traffic")"
else
  printf 'env:e2e passed for %s at %s; the cluster is destroyed.\n' "$environment" "$tested"
fi
