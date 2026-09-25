#!/usr/bin/env bash
#MISE description="Measure the traffic cilium:traffic-start began: fails when a conn-disrupt connection broke, any fortio request failed or fortio sent under 90% of the requested rate, prints the slowest request, and ends with whether the traffic crossed a Cilium agent restart; removes the test workloads when it passes"
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
if [[ ! "$run_id" =~ ^[1-9][0-9]*$ ]]; then
  fail "$traffic/fortio-run holds '$run_id', not a fortio run id; start a new run with: mise run cilium:traffic-start $environment"
fi
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

if ! cilium --kubeconfig "$kubeconfig" connectivity test --include-conn-disrupt-test \
  --conn-disrupt-test-restarts-path "$traffic/conn-disrupt-restarts" --test no-interrupted-connections; then
  problems+=("conn-disrupt: a connection held open since cilium:traffic-start broke; the cilium-cli output above names the pod")
fi

# wait=on returns once the run has ended and fortio has saved its result.
reply=$(fortio_rest "$kubeconfig" "rest/stop?runid=$run_id&wait=on") ||
  fail_with_problems "fortio did not stop run $run_id"
# Taken once the measured traffic has ended, so any agent restart during it
# counts.
cilium_agent_identities "$kubeconfig" >"$traffic/agent-after"
# A run that is already stopping replies with an empty ResultID.
result_id=$(jq -er '.ResultID | strings | select(test("^[A-Za-z0-9_-]+$"))' <<<"$reply") ||
  fail_with_problems "fortio did not stop run $run_id with a saved result; it replied: $reply"
fortio_rest "$kubeconfig" "data/$result_id.json" >"$traffic/result.json" ||
  fail_with_problems "fortio did not return result $result_id"
# jq accepts only a single, complete and consistent result, and every value
# bash arithmetic reads is a whole number: bash would evaluate any other
# text as an expression and read an error inside `if` as false. The rate
# and the return codes are only printed. jq also computes the minimum
# count, since fortio may report a fractional rate.
summary=$(jq -ser --argjson percent "$minimum_percent" '
  select(length == 1) | .[0]
  | def finite: type == "number" and (isinfinite | not) and (isnan | not);
  def whole: finite and . >= 0 and . < 1e15 and . == floor;
  ((.RequestedQPS | tonumber?) // null) as $qps
  | select((.DurationHistogram.Count | whole) and .DurationHistogram.Count > 0
    and (.DurationHistogram.Max | finite and . >= 0)
    and (.ActualDuration | whole) and .ActualDuration > 0
    and (.RetCodes | type == "object") and all(.RetCodes[]; whole)
    and ([.RetCodes[]] | add) == .DurationHistogram.Count
    and ($qps | finite and . > 0 and . < 1e6))
  | [ .DurationHistogram.Count,
      (.RetCodes["200"] // 0),
      (.DurationHistogram.Max * 1000 | round),
      (.ActualDuration / 1e9 | floor),
      $qps,
      (.ActualDuration / 1e9 * $qps * $percent / 100 | ceil),
      (.RetCodes | tojson) ]
  | @tsv' "$traffic/result.json") ||
  fail_with_problems "fortio result $result_id is malformed: it needs a positive whole DurationHistogram.Count, RetCodes that add up to it, a positive ActualDuration and a positive RequestedQPS; it is kept at $traffic/result.json"
read -r count answered slowest_ms duration requested_qps minimum_count codes <<<"$summary"
for value in "$count" "$answered" "$slowest_ms" "$duration" "$minimum_count"; do
  [[ "$value" =~ ^[0-9]+$ ]] ||
    fail_with_problems "fortio result $result_id gave '$value' where a whole number belongs; it is kept at $traffic/result.json"
done

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
snapshots_differ=0
diff -q "$traffic/agent-before" "$traffic/agent-after" >/dev/null || snapshots_differ=$?
case "$snapshots_differ" in
0) verdict="the Cilium agent was not restarted, so traffic continuity was not exercised" ;;
1) verdict="traffic held across the Cilium agent restart" ;;
*) fail_with_problems "the Cilium agent snapshots in $traffic could not be compared, so there is no verdict" ;;
esac
kubectl --kubeconfig "$kubeconfig" delete namespace traffic-probe --timeout=2m ||
  fail "$verdict, but removing the traffic-probe namespace failed"
cilium --kubeconfig "$kubeconfig" connectivity test --cleanup ||
  fail "$verdict, but removing the cilium-test namespaces failed"
rm -rf "$traffic"
printf '%s\n' "$verdict"
