#!/usr/bin/env bash
#MISE description="Start traffic that a Cilium agent restart must not break, for cilium:traffic-check to measure: cilium-cli conn-disrupt connections held open, and fortio opening 100 new connections a second through a ClusterIP Service (deploys test workloads)"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# How long, in whole seconds, a new fortio run may take to start sending.
readonly run_start_timeout="${FIRMAMENT_FORTIO_START_TIMEOUT:-30}"
# A leading zero would make bash arithmetic read the value as octal.
if [[ ! "$run_start_timeout" =~ ^(0|[1-9][0-9]*)$ ]]; then
  fail "FIRMAMENT_FORTIO_START_TIMEOUT must be whole seconds without a leading zero, not '$run_start_timeout'"
fi

init_environment "$environment"
claim_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
traffic=$(traffic_directory "$environment")
# A run that stopped before cilium:traffic-check leaves its state behind;
# this run replaces it.
rm -rf "$traffic"
mkdir -p "$traffic"

# A fortio run from an earlier traffic-start that stopped before writing
# its state keeps sending until stopped; a new namespace starts without it.
kubectl --kubeconfig "$kubeconfig" delete namespace traffic-probe --ignore-not-found --timeout=2m
kubectl --kubeconfig "$kubeconfig" apply -f "$MISE_PROJECT_ROOT/.mise/traffic/fortio.yaml"
kubectl --kubeconfig "$kubeconfig" -n traffic-probe rollout status \
  deployment/fortio-server deployment/fortio-client --timeout=3m

# Deploys client and server pairs whose clients exit, and so restart, when a
# reply on their open connection takes longer than 1 s, then records each
# pod's restart count.
cilium --kubeconfig "$kubeconfig" connectivity test --conn-disrupt-test-setup --include-conn-disrupt-test \
  --conn-disrupt-client-timeout 1s --conn-disrupt-test-restarts-path "$traffic/conn-disrupt-restarts" \
  --test no-interrupted-connections

# A started run that is not yet recorded in fortio-run keeps sending with
# nothing to stop it, so a traffic-start that fails stops it on exit.
stop_unrecorded_run() {
  if [[ -n "${run_id:-}" && ! -f "$traffic/fortio-run" ]]; then
    fortio_rest "$kubeconfig" "rest/stop?runid=$run_id" >/dev/null || true
  fi
}
trap stop_unrecorded_run EXIT

# 100 requests a second, each on a new connection with a 1 s timeout, until
# cilium:traffic-check stops the run. The REST API reads string values only.
reply=$(fortio_rest "$kubeconfig" \
  -payload '{"url":"http://fortio-server:8080/echo","qps":"100","t":"on","timeout":"1s","connection-reuse":"1:1","c":"4","async":"on","save":"on"}' \
  rest/run)
run_id=$(jq -er '.RunID | numbers | select(. >= 1 and . == floor)' <<<"$reply") || fail "fortio did not start a run; it replied: $reply"

# fortio replies before the run begins, and the run must be sending
# requests before whatever cilium:traffic-check measures starts.
deadline=$((SECONDS + run_start_timeout))
until
  state=$(fortio_run_state "$kubeconfig" "$run_id")
  [[ "$state" == running ]]
do
  if ((SECONDS >= deadline)); then
    fail "fortio run $run_id is not running after ${run_start_timeout}s (state '${state:-none}')"
  fi
  sleep 1
done
# Taken while both kinds of traffic run: cilium:traffic-check compares these
# pods with the ones it finds, so only a restart under traffic counts.
cilium_agent_identities "$kubeconfig" >"$traffic/agent-before"
# Written last: cilium:traffic-check reads a started run only from this file.
printf '%s\n' "$run_id" >"$traffic/fortio-run"
printf 'Traffic is running (fortio run %s). Measure it with: mise run cilium:traffic-check %s\n' "$run_id" "$environment"
