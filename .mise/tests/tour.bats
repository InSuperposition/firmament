#!/usr/bin/env bats

# mise run tour against stand-in tools: the UI tasks listen on their ports,
# and each guarantee task prints the result a real selector prints.

bats_require_minimum_version 1.5.0

load stubs.bash

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

setup() {
  setup_stubs
  state="$FIRMAMENT_STATE_HOME/environments/local"
  flux_port=$((20000 + RANDOM % 10000))
  hubble_port=$((30000 + RANDOM % 10000))
  checkout=$(git -C "$root_directory" rev-parse HEAD)
  printf 'kubeconfig_path: %s/admin.kubeconfig\nruntime_info: {git_commit: %s}\n' "$state" "$checkout" >"$state/cluster-access.yaml"
  results="$BATS_TEST_TMPDIR/results"
  mkdir -p "$results"
  local index=0 guarantee
  for guarantee in wrong-signer-chart-refused direct-access-denied-gateway-allowed unsigned-image-refused; do
    yq -o=json -I=0 ".actions[$index] | del(.started) | del(.finished)" "$root_directory/contracts/run-record/run-record.yaml" >"$results/$guarantee.json"
    index=$((index + 1))
  done
  own_stub mise
  cat >"$stubs/mise" <<STUB
#!/usr/bin/env bash
printf 'mise %s\n' "\$*" >>"\$CALLS"
case "\$*" in
  "run flux:ui --port "* | "run cilium:ui --port "*)
    if [[ -n "\${TOUR_UI_FAIL:-}" ]]; then
      echo "port-forward failed: boom" >&2
      exit 1
    fi
    port="\${!#}"
    while true; do nc -l "\$port"; done ;;
  "run env:apply") exit 0 ;;
  "run "*":verify --only "*)
    guarantee=\$(sed -E 's/.*--only ([a-z-]+).*/\1/' <<<"\$*")
    if [[ "\${TOUR_NO_RESULT:-}" == "\$guarantee" ]]; then exit 3; fi
    if [[ -n "\${TOUR_SLEEP:-}" ]]; then sleep "\$TOUR_SLEEP"; fi
    if [[ "\${TOUR_FAIL:-}" == "\$guarantee" ]]; then
      jq -c '.exit_status = 1 | .controls[-1].passed = false' "$results/\$guarantee.json"
      exit 1
    fi
    printf 'ok: %s\n' "\$guarantee"
    cat "$results/\$guarantee.json" ;;
esac
STUB
  chmod +x "$stubs/mise"
  own_stub curl
  cv_port=$((40000 + RANDOM % 10000))
  printf '#!/usr/bin/env bash\nprintf %%s "${CV_STATUS:-200}"\n' >"$stubs/curl"
  chmod +x "$stubs/curl"
}

teardown() {
  pkill -f "nc -l $flux_port" 2>/dev/null || true
  pkill -f "nc -l $hubble_port" 2>/dev/null || true
}

tour() {
  MISE_ENV=local TF_VAR_state_directory="$state" usage_yes="${YES:-true}" usage_flux_port="$flux_port" usage_hubble_port="$hubble_port" \
    usage_cv_port="$cv_port" run "$root_directory/.mise/tasks/tour.sh" "$@"
}

latest_record() {
  ls -t "$state"/evidence/record-*.json | head -n 1
}

@test "tour stops with the build command when no cluster is running" {
  forget_contract cluster-access.yaml
  tour
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise run env:apply"* && "$output" == *"mise run tour --build"* ]]
  ! grep -q 'mise run' "$CALLS" || fail "ran a task: $(cat "$CALLS")"
}

@test "tour proves the three guarantees in order and writes a complete record that the schema accepts" {
  tour
  [ "$status" -eq 0 ] || fail "$output"
  record=$(latest_record)
  cue vet -c -d '#Contract' "$root_directory/contracts/run-record/schema.cue" "$record"
  [ "$(jq -r .complete "$record")" = true ]
  [ "$(jq -r '[.actions[].guarantee] | join(",")' "$record")" = "wrong-signer-chart-refused,direct-access-denied-gateway-allowed,unsigned-image-refused" ]
  [ "$(jq -r .revision.matches "$record")" = true ]
  [ "$(jq -r .revision.cluster "$record")" = "$checkout" ]
  ls "$state"/evidence/tour-*.log
  [[ "$output" == *"All 3 guarantees held."* ]]
  grep -q "mise run flux:ui --port $flux_port" "$CALLS"
  grep -q "mise run cilium:ui --port $hubble_port" "$CALLS"
  grep -q 'mise run tenant:verify --only wrong-signer-chart-refused$' "$CALLS"
}

@test "tour leaves nothing listening on the UI ports when it ends" {
  tour
  [ "$status" -eq 0 ] || fail "$output"
  sleep 1
  ! nc -z 127.0.0.1 "$flux_port" || fail "the Flux UI port is still open"
  ! nc -z 127.0.0.1 "$hubble_port" || fail "the Hubble UI port is still open"
}

@test "tour shows why a UI task exited" {
  TOUR_UI_FAIL=1 tour
  [ "$status" -ne 0 ]
  [[ "$output" == *"the process that should listen on local port $flux_port exited"* ]]
  [[ "$output" == *"port-forward failed: boom"* ]]
}

@test "tour stops before starting anything when a UI port is busy" {
  (while true; do nc -l "$flux_port"; done) &
  busy=$!
  sleep 0.5
  tour
  kill "$busy" 2>/dev/null || true
  pkill -f "nc -l $flux_port" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"local port $flux_port is already in use"* ]]
  ! grep -q 'mise run flux:ui' "$CALLS" || fail "started the Flux UI"
}

@test "tour says so in the record when the cluster runs another revision" {
  printf 'kubeconfig_path: %s/admin.kubeconfig\nruntime_info: {git_commit: 0123456789abcdef0123456789abcdef01234567}\n' "$state" >"$state/cluster-access.yaml"
  tour
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"Warning: the cluster runs 0123456789abcdef0123456789abcdef01234567"* ]]
  [ "$(jq -r .revision.matches "$(latest_record)")" = false ]
}

@test "tour stops at a failing guarantee and keeps an incomplete record" {
  TOUR_FAIL=direct-access-denied-gateway-allowed tour
  [ "$status" -ne 0 ]
  record=$(latest_record)
  cue vet -c -d '#Contract' "$root_directory/contracts/run-record/schema.cue" "$record"
  [ "$(jq -r .complete "$record")" = false ]
  [ "$(jq '.actions | length' "$record")" = 2 ]
  [ "$(jq -r '.actions[1].exit_status' "$record")" = 1 ]
  ! grep -q 'kyverno:verify' "$CALLS" || fail "ran the third guarantee after a failure"
}

@test "tour keeps a failed action when a task ends without a result" {
  TOUR_NO_RESULT=wrong-signer-chart-refused tour
  [ "$status" -ne 0 ]
  record=$(latest_record)
  cue vet -c -d '#Contract' "$root_directory/contracts/run-record/schema.cue" "$record"
  [ "$(jq -r .complete "$record")" = false ]
  [ "$(jq -r '.actions[0].controls[0].passed' "$record")" = false ]
  [ "$(jq -r '.actions[0].exit_status' "$record")" -ne 0 ]
}

@test "tour stopped mid-run leaves an incomplete record and no UI process" {
  MISE_ENV=local TF_VAR_state_directory="$state" usage_yes=true usage_flux_port="$flux_port" usage_hubble_port="$hubble_port" TOUR_SLEEP=30 \
    "$root_directory/.mise/tasks/tour.sh" >"$BATS_TEST_TMPDIR/tour.out" 2>&1 &
  tour_pid=$!
  for _ in $(seq 1 50); do
    grep -q 'tenant:verify' "$CALLS" 2>/dev/null && break
    sleep 0.2
  done
  kill -TERM "$tour_pid"
  wait "$tour_pid" || true
  sleep 1
  record=$(latest_record)
  [ "$(jq -r .complete "$record")" = false ]
  ! nc -z 127.0.0.1 "$flux_port" || fail "the Flux UI port is still open"
  ! nc -z 127.0.0.1 "$hubble_port" || fail "the Hubble UI port is still open"
}

@test "tour --build applies the environment before it starts any UI" {
  usage_build=true tour
  [ "$status" -eq 0 ] || fail "$output"
  apply_line=$(grep -n 'mise run env:apply' "$CALLS" | head -n 1 | cut -d: -f1)
  ui_line=$(grep -n 'mise run flux:ui' "$CALLS" | head -n 1 | cut -d: -f1)
  [ "$apply_line" -lt "$ui_line" ]
}

@test "tour waits for Enter and holds the refused chart source when it is not run with --yes" {
  YES=false tour <<<$'\n\n\n\n'
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"Press Enter to start."* ]]
  grep -q 'mise run tenant:verify --only wrong-signer-chart-refused --hold' "$CALLS"
  ! grep -q 'network-policy:verify --only direct-access-denied-gateway-allowed --hold' "$CALLS"
}

@test "tour opens the cv site through the Gateway when it answers from this machine" {
  tour
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"The cv site: http://192.0.2.10:8880/"* ]]
  ! grep -q 'port-forward' "$CALLS" || fail "started a port-forward: $(cat "$CALLS")"
}

@test "tour falls back to a port-forward to the cv service when the Gateway does not answer, and stops it" {
  CV_STATUS=000 tour
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"does not answer from this machine; using a port-forward"* ]]
  [[ "$output" == *"The cv site: http://localhost:$cv_port/"* ]]
  grep -q -- "-n cv port-forward svc/cv $cv_port:80" "$CALLS"
  sleep 1
  ! nc -z 127.0.0.1 "$cv_port" || fail "the cv port-forward is still open"
}
