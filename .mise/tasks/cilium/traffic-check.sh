#!/usr/bin/env bash
#MISE description="Measure the traffic cilium:traffic-start began: fails when a conn-disrupt connection broke or any fortio request failed, prints the slowest request, and ends with whether the traffic crossed a Cilium agent restart; removes the test workloads when it passes"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# The load cilium:traffic-start asks fortio for, and the share of it a run
# must reach to count as having run the whole time.
readonly requests_per_second=100 minimum_percent=90

init_environment "$environment"
claim_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
traffic=$(traffic_directory "$environment")
if [[ ! -f "$traffic/fortio-run" ]]; then
  fail "no traffic run started for environment '$environment'; start one with: mise run cilium:traffic-start $environment"
fi
run_id=$(<"$traffic/fortio-run")
running_since=$(<"$traffic/running-since")
checked_at=$(date +%s)
workload_identities "$kubeconfig" <(printf 'kube-system k8s-app=cilium\n') >"$traffic/agent-after"

problems=()
if ! cilium --kubeconfig "$kubeconfig" connectivity test --include-conn-disrupt-test \
  --conn-disrupt-test-restarts-path "$traffic/conn-disrupt-restarts" --test no-interrupted-connections; then
  problems+=("conn-disrupt: a connection held open since cilium:traffic-start broke; the cilium-cli output above names the pod")
fi

# wait=on returns once the run has ended and fortio has saved its result.
reply=$(fortio_rest "$kubeconfig" "http://localhost:8080/fortio/rest/stop?runid=$run_id&wait=on")
# A run that is already stopping replies with an empty ResultID.
result_id=$(jq -er '.ResultID | strings | select(. != "")' <<<"$reply") ||
  fail "fortio did not stop run $run_id with a saved result; it replied: $reply"
fortio_rest "$kubeconfig" "http://localhost:8080/fortio/data/$result_id.json" >"$traffic/result.json"
summary=$(jq -er '
  select(has("StartTime") and has("ActualDuration") and has("RetCodes") and has("DurationHistogram"))
  | [ .DurationHistogram.Count,
      (.RetCodes["200"] // 0),
      (.DurationHistogram.Max * 1000 | round),
      (.StartTime | sub("\\.[0-9]+"; "") | fromdateiso8601),
      (.ActualDuration / 1e9 | floor),
      (.RetCodes | tojson) ]
  | @tsv' "$traffic/result.json") ||
  fail "fortio result $result_id lacks StartTime, ActualDuration, RetCodes or DurationHistogram; it is kept at $traffic/result.json"
read -r count answered slowest_ms started duration codes <<<"$summary"

printf 'fortio: %s of %s requests answered 200 over %ss; the slowest took %s ms\n' "$answered" "$count" "$duration" "$slowest_ms"
if ((answered != count)); then
  problems+=("fortio: $((count - answered)) of $count requests failed (return codes $codes)")
fi
if ((started > running_since)); then
  problems+=("fortio: the run started at $started, after cilium:traffic-start saw it running at $running_since")
fi
if ((started + duration < checked_at)); then
  problems+=("fortio: the run ended at $((started + duration)), before cilium:traffic-check began at $checked_at")
fi
if ((count * 100 < duration * requests_per_second * minimum_percent)); then
  problems+=("fortio: $count requests in ${duration}s is under $minimum_percent% of the $requests_per_second a second asked for")
fi

if ((${#problems[@]} > 0)); then
  printf '%s\n' "${problems[@]}" >&2
  fail "The traffic-probe and cilium-test namespaces and $traffic are kept for inspection; the next cilium:traffic-start replaces them."
fi

kubectl --kubeconfig "$kubeconfig" delete namespace traffic-probe
cilium --kubeconfig "$kubeconfig" connectivity test --cleanup
if diff -q "$traffic/agent-before" "$traffic/agent-after" >/dev/null; then
  verdict="the Cilium agent was not restarted, so traffic continuity was not exercised"
else
  verdict="traffic held across the Cilium agent restart"
fi
rm -rf "$traffic"
printf '%s\n' "$verdict"
