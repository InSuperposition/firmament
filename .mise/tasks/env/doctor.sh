#!/usr/bin/env bash
#MISE description="Explain why an environment task would fail, without changing anything: one line per boundary, and the next command for each failure"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# The doctor reads state files and asks the host, the machine and the API
# server; it never initializes OpenTofu, claims the environment or starts
# anything. A missing cluster is not a failure: env:apply creates it.

failures=0

passed() {
  printf 'ok    %s: %s\n' "$1" "$2"
}

failed() {
  printf 'FAIL  %s: %s\n      next: %s\n' "$1" "$2" "$3"
  failures=$((failures + 1))
}

skipped() {
  printf 'skip  %s: %s\n' "$1" "$2"
}

# Runs one probe. A stalled OrbStack ignores TERM, so a probe still running
# 5 seconds after its 15 is killed. The probe stays in the terminal's
# foreground process group: `orb -m` sets terminal modes, which stops a
# process that timeout has moved to a background group until it times out.
probe() {
  timeout --foreground -k 5 15 "$@"
}

environment_directory "$environment" >/dev/null
state=$(state_directory "$environment")
passed environment "$environment"

owner=$(cat "$state/owner" 2>/dev/null) || owner=""
if [[ -n "$owner" && "$owner" != "$(current_worktree)" && -d "$owner" ]]; then
  failed owner "the worktree $owner owns this environment" "run the task there, or set FIRMAMENT_TAKE_OVER=1"
else
  passed owner "no other worktree owns this environment"
fi

state_problem=""
for file in "$state/terraform.tfstate" "$state/bootstrap.tfstate"; do
  if ! problem=$(refuse_empty_state "$file" 2>&1); then
    failed state "$problem" "restore $file from $file.backup"
    state_problem=1
  fi
done
[[ -n "$state_problem" ]] || passed state "readable"

orbstack=$(probe orbctl status 2>&1) || true
if [[ "$orbstack" == Running ]]; then
  passed orbstack running
else
  failed orbstack "OrbStack is ${orbstack:-not answering}" "orbctl start"
fi

machine="" kubeconfig=""
if [[ -z "$state_problem" && -s "$state/terraform.tfstate" ]]; then
  if outputs=$(tofu output -json -state="$state/terraform.tfstate" 2>&1); then
    machine=$(jq -r '.machine_name.value // empty' <<<"$outputs")
    kubeconfig=$(jq -r '.kubeconfig_path.value // empty' <<<"$outputs")
  else
    failed state "cannot read the outputs in $state/terraform.tfstate: $(head -n 1 <<<"$outputs")" \
      "restore $state/terraform.tfstate from $state/terraform.tfstate.backup"
  fi
fi

if [[ -z "$machine" ]]; then
  skipped machine "no cluster recorded yet; env:apply creates it"
  skipped api "no cluster recorded yet"
elif [[ "$orbstack" != Running ]]; then
  skipped machine "OrbStack is not running"
  skipped api "OrbStack is not running"
else
  machine_state=$(probe orb info "$machine" --format json 2>/dev/null | jq -r '.record.state // empty') || machine_state=""
  if [[ "$machine_state" == running ]]; then
    passed machine "$machine is running"
  elif [[ -n "$machine_state" ]]; then
    failed machine "$machine is $machine_state" "orb start $machine"
  else
    failed machine "the state records $machine, but OrbStack has no such machine" "mise run env:apply $environment"
  fi

  if probe dscacheutil -q host -a name "$machine.orb.local" | grep -q address; then
    passed "host dns" "the Mac resolves $machine.orb.local"
  else
    failed "host dns" "the Mac cannot resolve $machine.orb.local" "orb restart $machine, then mise run orb:capture-stall $machine if it persists"
  fi

  if [[ "$machine_state" != running ]]; then
    skipped "machine dns" "the machine is not running"
    skipped api "the machine is not running"
  else
    # host.orb.internal reaches the host's containers; ghcr.io stands for
    # every image registry the node pulls from.
    for name in host.orb.internal ghcr.io; do
      if probe orb -m "$machine" getent hosts "$name" >/dev/null; then
        passed "machine dns" "$machine resolves $name"
      else
        failed "machine dns" "$machine cannot resolve $name" "orb restart $machine; if public names fail, check the Mac's network"
      fi
    done

    if [[ -z "$kubeconfig" ]]; then
      skipped api "no kubeconfig recorded yet; env:apply writes it"
    elif error=$(probe kubectl --kubeconfig "$kubeconfig" get --raw /readyz 2>&1 >/dev/null); then
      passed api "the API server is ready"
    elif [[ "$error" == *"no route to host"* ]]; then
      failed api "no route to the API server; a background agent session without macOS Local Network access gets this" \
        "allow the app in System Settings > Privacy & Security > Local Network, or run from a terminal"
    else
      failed api "$(head -n 1 <<<"$error")" "mise run k0s:verify $environment"
    fi
  fi
fi

if ((failures > 0)); then
  printf '%d check(s) failed.\n' "$failures"
  exit 1
fi
printf 'Nothing blocks the environment tasks.\n'
