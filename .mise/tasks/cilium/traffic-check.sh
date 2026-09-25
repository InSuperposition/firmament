#!/usr/bin/env bash
#MISE description="Measure the traffic cilium:traffic-start began: fails when a conn-disrupt connection broke or any fortio request failed, prints the slowest request, and ends with whether the traffic crossed a Cilium agent restart; removes the test workloads when it passes"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

# The share of the requested rate a run must reach to count as having run
# throughout.
readonly minimum_percent=90

init_environment "$environment"
claim_environment "$environment"
kubeconfig=$(environment_kubeconfig "$environment")
traffic=$(traffic_directory "$environment")
if [[ ! -f "$traffic/fortio-run" ]]; then
  fail "no traffic run started for environment '$environment'; start one with: mise run cilium:traffic-start $environment"
fi
run_id=$(<"$traffic/fortio-run")
problems=()

# Prints the problems found so far, then fails with the given reason and
# says what is kept.
fail_with_problems() {
  if ((${#problems[@]} > 0)); then
    printf '%s\n' "${problems[@]}" >&2
  fi
  fail "$*"$'\n'"The traffic-probe and cilium-test-1 namespaces and $traffic are kept for inspection; the next cilium:traffic-start replaces them."
}

# cilium:traffic-start saw the run sending before it returned; still
# sending now means it covered everything in between. A run already
# stopped, or state left from a destroyed cluster, has nothing to measure.
state=$(fortio_run_state "$kubeconfig" "$run_id")
if [[ "$state" != running ]]; then
  fail "fortio run $run_id is not running (state '${state:-none}'), so there is nothing to measure; start a new run with: mise run cilium:traffic-start $environment"
fi
cilium_agent_identities "$kubeconfig" >"$traffic/agent-after"

if ! cilium --kubeconfig "$kubeconfig" connectivity test --include-conn-disrupt-test \
  --conn-disrupt-test-restarts-path "$traffic/conn-disrupt-restarts" --test no-interrupted-connections; then
  problems+=("conn-disrupt: a connection held open since cilium:traffic-start broke; the cilium-cli output above names the pod")
fi

# wait=on returns once the run has ended and fortio has saved its result.
reply=$(fortio_rest "$kubeconfig" "rest/stop?runid=$run_id&wait=on") ||
  fail_with_problems "fortio did not stop run $run_id"
# A run that is already stopping replies with an empty ResultID.
result_id=$(jq -er '.ResultID | strings | select(test("^[A-Za-z0-9_-]+$"))' <<<"$reply") ||
  fail_with_problems "fortio did not stop run $run_id with a saved result; it replied: $reply"
fortio_rest "$kubeconfig" "data/$result_id.json" >"$traffic/result.json" ||
  fail_with_problems "fortio did not return result $result_id"
# Only numbers leave jq: bash arithmetic would evaluate any other text as
# an expression. jq also computes the minimum count, since fortio may
# report a fractional rate.
summary=$(jq -er --argjson percent "$minimum_percent" '
  select((.DurationHistogram.Count | type) == "number"
    and (.DurationHistogram.Max | type) == "number"
    and (.ActualDuration | type) == "number"
    and (.RetCodes | type) == "object" and all(.RetCodes[]; type == "number")
    and ((.RequestedQPS | tonumber?) // null | type) == "number")
  | (.RequestedQPS | tonumber) as $qps
  | [ (.DurationHistogram.Count | floor),
      (.RetCodes["200"] // 0 | floor),
      (.DurationHistogram.Max * 1000 | round),
      (.ActualDuration / 1e9 | floor),
      $qps,
      (.ActualDuration / 1e9 * $qps * $percent / 100 | ceil),
      (.RetCodes | tojson) ]
  | @tsv' "$traffic/result.json") ||
  fail_with_problems "fortio result $result_id lacks a numeric RequestedQPS, ActualDuration, RetCodes or DurationHistogram; it is kept at $traffic/result.json"
read -r count answered slowest_ms duration requested_qps minimum_count codes <<<"$summary"

printf 'fortio: %s of %s requests answered 200 over %ss; the slowest took %s ms\n' "$answered" "$count" "$duration" "$slowest_ms"
if ((answered != count)); then
  problems+=("fortio: $((count - answered)) of $count requests failed (return codes $codes)")
fi
if ((count < minimum_count)); then
  problems+=("fortio: $count requests in ${duration}s is under $minimum_percent% of the $requested_qps a second asked for")
fi
if ((${#problems[@]} > 0)); then
  fail_with_problems "the traffic did not survive; see the problems above"
fi

# Decided before cleanup, so a missing snapshot keeps everything for
# inspection instead of reading as a restart.
if [[ ! -s "$traffic/agent-before" || ! -s "$traffic/agent-after" ]]; then
  fail_with_problems "a Cilium agent snapshot in $traffic is missing or empty, so there is no verdict"
fi
if diff -q "$traffic/agent-before" "$traffic/agent-after" >/dev/null; then
  verdict="the Cilium agent was not restarted, so traffic continuity was not exercised"
else
  verdict="traffic held across the Cilium agent restart"
fi
kubectl --kubeconfig "$kubeconfig" delete namespace traffic-probe --timeout=2m
cilium --kubeconfig "$kubeconfig" connectivity test --cleanup
rm -rf "$traffic"
printf '%s\n' "$verdict"
