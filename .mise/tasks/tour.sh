#!/usr/bin/env bash
#MISE description="Show the platform's guarantees live: open the Flux and Hubble UIs and the cv site, prove three guarantees one by one, and write a run record of what was observed; attaches to the running environment (--build applies it first)"
#USAGE flag "--build" help="Run env:apply first (about 8 minutes; needs a clean checkout pushed to origin)"
#USAGE flag "--yes" help="Do not wait for Enter between the steps; the refused chart source is then removed at once"
#USAGE flag "--flux-port <port>" help="Local port of the Flux Web UI (default 9080)"
#USAGE flag "--hubble-port <port>" help="Local port of the Hubble UI (default 12000)"
#USAGE flag "--cv-port <port>" help="Local port for the cv site when the Gateway does not answer from this machine (default 18080)"
set -euo pipefail
# shellcheck source=../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../lib-probe.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-probe.sh"
# shellcheck source=../lib-record.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-record.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment=$(require_environment) || exit
flux_port="${usage_flux_port:-9080}"
hubble_port="${usage_hubble_port:-12000}"
cv_port="${usage_cv_port:-18080}"
assume_yes="${usage_yes:-false}"

if [[ "${usage_build:-}" == true ]]; then
  mise run env:apply
fi

# The tour attaches to a cluster that is already running.
if ! kubeconfig=$(environment_kubeconfig 2>/dev/null) || [[ ! -f "$kubeconfig" ]]; then
  fail "no running cluster for environment $environment; build one with: mise run env:apply (or run: mise run tour --build)" || exit
fi

# What the tour writes, beside the private state of the environment.
evidence_directory="${TF_VAR_state_directory:?run this through mise}/evidence"
mkdir -p "$evidence_directory"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log_file="$evidence_directory/tour-$stamp.log"
record_file="$evidence_directory/record-$stamp.json"
exec > >(tee -a "$log_file") 2>&1

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

readonly -a guarantees=(wrong-signer-chart-refused direct-access-denied-gateway-allowed unsigned-image-refused)
readonly -a tasks=(tenant:verify network-policy:verify kyverno:verify)
readonly -a headings=(
  "a chart whose signer does not match is refused by Flux (watch the Flux UI)"
  "a pod in default cannot reach the cv pod directly, and the Gateway still serves cv (watch the Hubble UI)"
  "an unsigned image is refused at admission (watch this terminal)"
)

started=$(now)
actions='[]'
ui_pids=()
record_written=false

# Stops the two UI tasks and anything still listening on their ports.
stop_uis() {
  local pid port
  for pid in "${ui_pids[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  for port in "$flux_port" "$hubble_port" "$cv_port"; do
    for pid in $(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true); do
      kill -TERM "$pid" 2>/dev/null || true
    done
  done
}

# Writes the run record: complete only when $1 is true. A record is written to
# a partial file and moved into place, so a reader never sees half of one.
write_record() {
  local complete="$1" matches=false partial="$evidence_directory/partial-$stamp.json"
  [[ "$checkout_revision" == "$cluster_revision" ]] && matches=true
  jq -n --arg started "$started" --arg finished "$(now)" --arg checkout "$checkout_revision" --arg cluster "$cluster_revision" \
    --argjson matches "$matches" --argjson complete "$complete" --argjson actions "$actions" \
    '{schema: 1, started: $started, finished: $finished, revision: {checkout: $checkout, cluster: $cluster, matches: $matches}, complete: $complete, actions: $actions}' >"$partial"
  if ! cue vet -c -d '#Contract' "$MISE_PROJECT_ROOT/contracts/run-record/schema.cue" "$partial"; then
    fail "the run record does not match contracts/run-record; kept at $partial"
    return 1
  fi
  mv "$partial" "$record_file"
  record_written=true
}

finish() {
  local status=$?
  trap - EXIT
  stop_uis
  if [[ "$record_written" == false && -n "${checkout_revision:-}" && -n "${cluster_revision:-}" ]]; then
    write_record false || true
  fi
  if [[ -f "$record_file" ]]; then
    printf 'Run record: %s\nLog: %s\n' "$record_file" "$log_file"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# Preflight: the cluster answers, runs this checkout, and is ready.
printf 'Preflight\n'
kubectl --kubeconfig "$kubeconfig" get nodes >/dev/null ||
  fail "the cluster of environment $environment does not answer; is it running? mise run env:doctor looks at it" || exit
checkout_revision=$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD) || exit
cluster_revision=$(contract_field cluster-access.yaml .runtime_info.git_commit) ||
  fail "the cluster-access contract of environment $environment records no git_commit; build the cluster again with: mise run env:apply" || exit
if [[ "$checkout_revision" != "$cluster_revision" ]]; then
  printf 'Warning: the cluster runs %s but this checkout is at %s; the record says so.\n' "$cluster_revision" "$checkout_revision"
fi
kubectl --kubeconfig "$kubeconfig" -n flux-system wait kustomizations.kustomize.toolkit.fluxcd.io --all --for=condition=Ready --timeout=60s >/dev/null ||
  fail "the Flux Kustomizations are not all Ready; wait for them or look at them with: mise run flux:ui" || exit
kubectl --kubeconfig "$kubeconfig" -n cv wait pod --all --for=condition=Ready --timeout=60s >/dev/null ||
  fail "the pods of the cv tenant are not all Ready" || exit
require_free_local_port "$flux_port" || exit
require_free_local_port "$hubble_port" || exit
printf 'ok: the cluster answers, runs %s, and is ready\n' "$cluster_revision"

# The two UI tasks run until stopped, each in a process group of its own, so
# stopping the tour stops them and their port-forwards.
printf 'Starting the Flux UI on port %s and the Hubble UI on port %s\n' "$flux_port" "$hubble_port"
set -m
mise run flux:ui --port "$flux_port" >/dev/null 2>&1 &
ui_pids+=($!)
mise run cilium:ui --port "$hubble_port" >/dev/null 2>&1 &
ui_pids+=($!)
set +m
wait_for_local_port "${ui_pids[0]}" "$flux_port" 60 || exit
wait_for_local_port "${ui_pids[1]}" "$hubble_port" 60 || exit

# The cv site, through the Gateway; when the Gateway does not answer from this
# machine, through a port-forward to the cv service instead.
cv_url=""
if endpoint=$(gateway_endpoint 2>/dev/null); then
  read -r address port <<<"$endpoint"
  if [[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$address:$port/" 2>/dev/null || true)" == 200 ]]; then
    cv_url="http://$address:$port/"
  else
    printf 'The Gateway at %s:%s does not answer from this machine; using a port-forward to the cv service.\n' "$address" "$port"
  fi
else
  printf 'The Gateway has no address yet; using a port-forward to the cv service.\n'
fi
if [[ -z "$cv_url" ]]; then
  require_free_local_port "$cv_port" || exit
  set -m
  kubectl --kubeconfig "$kubeconfig" -n cv port-forward svc/cv "$cv_port:80" >/dev/null 2>&1 &
  ui_pids+=($!)
  set +m
  wait_for_local_port "${ui_pids[2]}" "$cv_port" 30 || exit
  cv_url="http://localhost:$cv_port/"
fi
open "$cv_url"
printf 'The cv site: %s\n' "$cv_url"

# Runs the guarantee $1 (an index) and appends its action to the record.
run_action() {
  local index="$1" guarantee task heading action_started status result output
  guarantee="${guarantees[$index]}"
  task="${tasks[$index]}"
  heading="${headings[$index]}"
  printf '\nStep %d of %d: %s\n' "$((index + 1))" "${#guarantees[@]}" "$heading"
  if [[ "$assume_yes" != true ]]; then
    printf 'Press Enter to start. '
    read -r _ || true
  fi
  local -a arguments=(--only "$guarantee")
  if [[ "$index" -eq 0 && "$assume_yes" != true ]]; then
    arguments+=(--hold)
  fi
  output=$(mktemp)
  action_started=$(now)
  status=0
  mise run "$task" "${arguments[@]}" 2>&1 | tee "$output" || status=${PIPESTATUS[0]}
  result=$(grep '^{"guarantee"' "$output" | tail -n 1 || true)
  rm -f "$output"
  if [[ -z "$result" ]]; then
    # The task ended before it could report: keep a failed action.
    status=$((status == 0 ? 1 : status))
    result=$(jq -nc --arg guarantee "$guarantee" --arg command "mise run $task ${arguments[*]}" --argjson status "$status" --arg line "$record_marker" \
      '{guarantee: $guarantee, command: $command, exit_status: $status, controls: [{name: "the guarantee ran", passed: false}], observations: [{kind: "condition", line: $line}]}')
  fi
  actions=$(jq -c --argjson result "$result" --arg started "$action_started" --arg finished "$(now)" \
    '. + [$result + {started: $started, finished: $finished}]' <<<"$actions")
  return "$status"
}

complete=true
for index in "${!guarantees[@]}"; do
  if ! run_action "$index"; then
    printf 'Step %d failed: %s\n' "$((index + 1))" "${guarantees[$index]}"
    complete=false
    break
  fi
done

write_record "$complete" || exit
if [[ "$complete" == true ]]; then
  printf '\nAll %d guarantees held.\n' "${#guarantees[@]}"
else
  exit 1
fi
