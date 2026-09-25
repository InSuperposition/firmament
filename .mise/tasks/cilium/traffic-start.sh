#!/usr/bin/env bash
#MISE description="Start traffic that a Cilium agent restart must not break, for cilium:traffic-check to measure: cilium-cli conn-disrupt connections held open, and fortio opening 100 new connections a second through a ClusterIP Service (deploys test workloads)"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# fortio's run state while it sends requests (StateRunning).
readonly fortio_running=2

init_environment "$environment"
claim_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
traffic=$(traffic_directory "$environment")
# A run that stopped before cilium:traffic-check leaves its state behind;
# this run replaces it.
rm -rf "$traffic"
mkdir -p "$traffic"

kubectl --kubeconfig "$kubeconfig" apply -f "$MISE_PROJECT_ROOT/.mise/traffic/fortio.yaml"
kubectl --kubeconfig "$kubeconfig" -n traffic-probe rollout status \
  deployment/fortio-server deployment/fortio-client --timeout=3m

# cilium:traffic-check compares these pods with the ones it finds, to tell
# whether the traffic crossed an agent restart.
workload_identities "$kubeconfig" <(printf 'kube-system k8s-app=cilium\n') >"$traffic/agent-before"

# Deploys client and server pairs whose clients exit, and so restart, when a
# reply on their open connection takes longer than 1 s, then records each
# pod's restart count.
cilium --kubeconfig "$kubeconfig" connectivity test --conn-disrupt-test-setup --include-conn-disrupt-test \
  --conn-disrupt-client-timeout 1s --conn-disrupt-test-restarts-path "$traffic/conn-disrupt-restarts" \
  --test no-interrupted-connections

# 100 requests a second, each on a new connection with a 1 s timeout, until
# cilium:traffic-check stops the run. The REST API reads string values only.
reply=$(fortio_rest "$kubeconfig" \
  -payload '{"url":"http://fortio-server:8080/echo","qps":"100","t":"on","timeout":"1s","connection-reuse":"1:1","c":"4","async":"on","save":"on"}' \
  http://localhost:8080/fortio/rest/run)
run_id=$(jq -er '.RunID // empty' <<<"$reply") || fail "fortio did not start a run; it replied: $reply"

# fortio replies before the run begins, and the run must be sending
# requests before whatever cilium:traffic-check measures starts.
deadline=$((SECONDS + 30))
until
  state=$(fortio_rest "$kubeconfig" "http://localhost:8080/fortio/rest/status?runid=$run_id" |
    jq -r --arg run "$run_id" '.Statuses[$run].State // empty')
  [[ "$state" == "$fortio_running" ]]
do
  if ((SECONDS >= deadline)); then
    fail "fortio run $run_id is not running after 30s (state '${state:-none}')"
  fi
  sleep 1
done
date +%s >"$traffic/running-since"
# Written last: cilium:traffic-check reads a started run only from this file.
printf '%s\n' "$run_id" >"$traffic/fortio-run"
printf 'Traffic is running (fortio run %s). Measure it with: mise run cilium:traffic-check %s\n' "$run_id" "$environment"
