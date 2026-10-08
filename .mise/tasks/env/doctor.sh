#!/usr/bin/env bash
#MISE description="Explain why an environment task would fail, without changing anything: one line per boundary, and the next command for each failure"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
environment=$(require_environment)

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

# Asks the API server from inside the machine, which needs neither the
# kubeconfig's address nor macOS Local Network access. Succeeds only when
# that answers.
answers_inside_machine() {
  probe orb -m "$1" sudo k0s kubectl get --raw /readyz >/dev/null 2>&1
}

state="$TF_VAR_state_directory"
passed environment "$environment"

owner=$(cat "$state/owner" 2>/dev/null) || owner=""
if [[ -n "$owner" && "$owner" != "$(current_worktree)" && -d "$owner" ]]; then
  failed owner "the worktree $owner owns this environment" "run the task there, or set FIRMAMENT_TAKE_OVER=1"
else
  passed owner "no other worktree owns this environment"
fi

state_problem=""
for root in machine-orb kubernetes-k0s bootstrap-flux; do
  file="$state/$root.tfstate"
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

# What is recorded comes from the contract files: each root deletes its own
# when it is destroyed.
machine="" kubeconfig="" cluster=""
if [[ -z "$state_problem" ]]; then
  if ! machine=$(contract_field_or_empty machine-hosts.yaml .name 2>&1); then
    failed state "cannot read $state/machine-hosts.yaml: $(head -n 1 <<<"$machine")" "mise run orb:apply, which writes it again"
    machine=""
  fi
  if ! kubeconfig=$(contract_field_or_empty cluster-access.yaml .kubeconfig_path 2>&1); then
    failed state "cannot read $state/cluster-access.yaml: $(head -n 1 <<<"$kubeconfig")" "mise run k0s:apply $environment, which writes it again"
    kubeconfig=""
  fi
  [[ -z "$kubeconfig" ]] || cluster=1
fi

if [[ -z "$machine" ]]; then
  skipped machine "no machine recorded yet; env:apply creates it"
  skipped api "no cluster recorded yet; env:apply creates it"
elif [[ "$orbstack" != Running ]]; then
  skipped machine "OrbStack is not running"
  skipped api "OrbStack is not running"
else
  machine_info=$(probe orb info "$machine" --format json 2>/dev/null) || machine_info=""
  machine_state=$(jq -r '.record.state // empty' <<<"$machine_info" 2>/dev/null) || machine_state=""
  if [[ "$machine_state" == running ]]; then
    passed machine "$machine is running"
  elif [[ -n "$machine_state" ]]; then
    failed machine "$machine is $machine_state" "orb start $machine"
  else
    failed machine "the state records $machine, but OrbStack has no such machine" "mise run env:apply"
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

    if [[ -z "$cluster" ]]; then
      skipped api "no cluster recorded yet; env:apply creates it"
    elif [[ -z "$kubeconfig" || ! -f "$kubeconfig" ]]; then
      # k0s:apply writes it again. env:apply cannot: it first asks the
      # cluster whether k0s installs charts, through this kubeconfig.
      failed api "the kubeconfig file ${kubeconfig:-(none recorded)} is missing" "mise run k0s:apply $environment"
    elif error=$(probe kubectl --kubeconfig "$kubeconfig" get --raw /readyz 2>&1 >/dev/null); then
      passed api "the API server is ready"
    elif [[ "$error" == *"no route to host"* ]]; then
      # k0s:apply writes the kubeconfig with the loopback address OrbStack
      # forwards; an older one names the machine's own address, which macOS
      # Local Network blocks for a background agent session.
      failed api "no route to the address the kubeconfig names: $(head -n 1 <<<"$error")" \
        "mise run k0s:apply $environment, which writes the kubeconfig with the loopback address"
    elif answers_inside_machine "$machine"; then
      # The API is ready on the machine, so OrbStack's forward to the host
      # is what stopped answering.
      failed api "the machine answers inside but the kubeconfig's address does not: $(head -n 1 <<<"$error")" \
        "orb restart $machine, then mise run orb:capture-stall $machine if it persists"
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
