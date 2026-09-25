#!/usr/bin/env bats

load stubs.bash

setup() {
  setup_stubs
}

task_scripts() {
  find "$root_directory/.mise/tasks" -name '*.sh' | sort
}

environment_scripts() {
  task_scripts | xargs grep -l '^#USAGE arg "\[environment\]"'
}

# Runs a task script the way mise does, with the environment argument set.
# cilium:conformance forwards Hubble Relay to a random high port, so a real
# forward on its default port does not collide with the tests.
run_task() {
  local script="$1" environment="$2"
  usage_environment="$environment" usage_hubble_port=$((20000 + RANDOM % 20000)) run "$script"
}

@test "every task script is executable, described and strict" {
  local script
  for script in $(task_scripts); do
    [ -x "$script" ] || fail "$script is not executable, so mise hides it"
    grep -q '^#MISE description="' "$script" || fail "$script has no description"
    grep -qx 'set -euo pipefail' "$script" || fail "$script does not run with set -euo pipefail"
  done
}

@test "every environment task stops at an unknown environment before calling any tool" {
  local script
  for script in $(environment_scripts); do
    run_task "$script" nowhere
    [ "$status" -ne 0 ] || fail "$script accepted an unknown environment"
    [[ "$output" == *"unknown environment 'nowhere'"* ]] || fail "$script: $output"
    [ ! -e "$CALLS" ] || fail "$script called $(cat "$CALLS")"
  done
}

@test "read-only tasks never apply or destroy" {
  local script
  # env:verify reads origin's branch tip, so the tasks run in a pushed checkout.
  e2e_repository environment/local/tests/cluster/chainsaw-test.yaml
  for script in $(environment_scripts); do
    case "$(basename "$script")" in
    # e2e.sh destroys through `mise run`; its own tests check what it runs.
    # The traffic tasks deploy workloads and measure a run started earlier;
    # their own tests below check them.
    apply.sh | destroy.sh | e2e.sh | traffic-start.sh | traffic-check.sh) continue ;;
    esac
    rm -f "$CALLS"
    run_task "$script" local
    [ "$status" -eq 0 ] || fail "$script: $output"
    ! grep -Eq '^tofu .* (apply|destroy)( |$)' "$CALLS" || fail "$script changed infrastructure: $(cat "$CALLS")"
  done
}

@test "destructive tasks ask for confirmation" {
  local script
  for script in "$root_directory"/.mise/tasks/*/destroy.sh "$root_directory/.mise/tasks/env/e2e.sh"; do
    grep -q '^#MISE confirm="' "$script" || fail "$script destroys without confirmation"
  done
}

@test "every task that changes an environment claims it first" {
  local script
  for script in "$root_directory"/.mise/tasks/*/apply.sh "$root_directory"/.mise/tasks/*/destroy.sh \
    "$root_directory/.mise/tasks/env/e2e.sh" "$root_directory"/.mise/tasks/cilium/{conformance,traffic-start,traffic-check}.sh; do
    grep -q '^claim_environment "\$environment"$' "$script" || fail "$script changes the environment without claiming it"
  done
}

@test "env:apply refuses an environment another worktree owns, before applying" {
  mkdir -p "$BATS_TEST_TMPDIR/other-worktree" "$FIRMAMENT_STATE_HOME/environment/local"
  printf '%s\n' "$BATS_TEST_TMPDIR/other-worktree" >"$FIRMAMENT_STATE_HOME/environment/local/owner"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to the worktree $BATS_TEST_TMPDIR/other-worktree"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

# Gives the local environment a state file, as any applied environment has.
local_state() {
  mkdir -p "$FIRMAMENT_STATE_HOME/environment/local"
  : >"$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate"
}

@test "env:destroy forgets the Flux bootstrap before destroying the rest" {
  local_state
  STATE_LIST=$'module.bootstrap_flux.helm_release.this\nmodule.vm_orb.orbstack_machine.this' run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^tofu .* (state rm|destroy) ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *" state rm -backup=$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate.bootstrap.backup module.bootstrap_flux "* ]]
  [[ "${lines[1]}" == *" destroy -input=false -auto-approve "* ]]
}

@test "env:destroy destroys without touching state when there is no bootstrap" {
  local_state
  STATE_LIST=module.vm_orb.orbstack_machine.this run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  run grep -c ' state rm ' "$CALLS"
  [ "$output" = 0 ]
  grep -q ' destroy -input=false -auto-approve ' "$CALLS"
}

@test "env:destroy runs on a fresh machine with no state yet" {
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  [ "$(grep -c ' state ' "$CALLS")" -eq 0 ]
  grep -q ' destroy -input=false -auto-approve ' "$CALLS"
}

@test "env:destroy runs from a detached HEAD" {
  unset FIRMAMENT_GIT_BRANCH
  e2e_repository
  git -C "$MISE_PROJECT_ROOT" checkout -q --detach
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  grep -q ' destroy -input=false -auto-approve .*branch=main$' "$CALLS"
}

@test "orb:destroy forgets the Flux bootstrap before destroying the machine" {
  local_state
  STATE_LIST=module.bootstrap_flux.helm_release.this run_task "$root_directory/.mise/tasks/orb/destroy.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^tofu .* (state rm|destroy) ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *" state rm "*" module.bootstrap_flux "* ]]
  [[ "${lines[1]}" == *" destroy -input=false -auto-approve -target=module.vm_orb "* ]]
}

@test "env:apply refuses a recorded cluster that cannot say whether k0s installs charts" {
  K0S_CHARTS_ERROR="Unable to connect to the server: dial tcp: i/o timeout" run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell whether k0s installs Helm charts"*"i/o timeout"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply refuses an environment whose state it cannot read" {
  OUTPUT_ERROR="Error: Failed to load state: lock held" run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to load state: lock held"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply applies a destroyed environment without asking it for k0s charts" {
  # The stub keeps printing no outputs after the apply, so the wait that
  # follows fails, and only there.
  NO_OUTPUTS=1 run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' has no kubeconfig_path in its state"* ]]
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
  ! grep -q 'get charts.helm.k0sproject.io' "$CALLS"
}

@test "env:apply applies a cluster where k0s installs no charts" {
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ]
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
}

@test "env:apply refuses a cluster whose Helm charts k0s still installs" {
  K0S_CHARTS=chart.helm.k0sproject.io/k0s-addon-chart-cilium run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0s still installs Helm charts on this cluster"*"k0s-addon-chart-cilium"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply waits for the cluster only after applying" {
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ]
  run grep -nE '^(tofu .* apply |cilium )' "$CALLS"
  [[ "${lines[0]}" == *"apply -input=false -auto-approve"* ]]
  [[ "${lines[1]}" == *"cilium --kubeconfig /state/admin.kubeconfig status"* ]]
}

@test "k0s:apply applies only the cluster and its kubeconfig, then waits for the node" {
  NODES=node/firmament run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ]
  run grep -nE '^(tofu .* apply |kubectl |cilium )' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"apply -input=false -auto-approve -target=module.orch_k0s -target=local_sensitive_file.kubeconfig "* ]]
  [[ "${lines[1]}" == *"kubectl --kubeconfig /state/admin.kubeconfig get nodes -o name "* ]]
}

@test "verify runs every *:verify task, one at a time, env:verify first" {
  run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%% |*}" = "mise run env:verify local" ]
  [ "${lines[1]%% |*}" = "mise run a:verify local" ]
  [ "${lines[2]%% |*}" = "mise run k0s:verify local" ]
}

@test "cilium:verify waits for the release to run Flux's values, then for the rollout, then for Cilium" {
  run_task "$root_directory/.mise/tasks/cilium/verify.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^(kubectl|helm|cilium) ' "$CALLS"
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system get configmap cilium-values "* ]]
  [[ "${lines[1]}" == "helm --kubeconfig /state/admin.kubeconfig -n kube-system get values cilium -o yaml "* ]]
  [[ "${lines[2]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system rollout status daemonset/cilium --timeout=10m "* ]]
  [[ "${lines[3]}" == "cilium --kubeconfig /state/admin.kubeconfig status --wait --interactive=false "* ]]
}

@test "tofu:test initializes and tests each suite directory, and never applies" {
  MISE_PROJECT_ROOT=$(make_repository modules/a/tests/unit.tftest.hcl environment/e/tests/wiring.tftest.hcl)
  run "$root_directory/.mise/tasks/tofu/test.sh"
  [ "$status" -eq 0 ]
  run cut -d"|" -f1 "$CALLS"
  [ "${lines[0]}" = "tofu -chdir=$MISE_PROJECT_ROOT/environment/e init -backend=false -input=false -reconfigure -lockfile=readonly " ]
  [ "${lines[1]}" = "tofu -chdir=$MISE_PROJECT_ROOT/environment/e test " ]
  [ "${lines[2]}" = "tofu -chdir=$MISE_PROJECT_ROOT/modules/a init -backend=false -input=false -reconfigure -lockfile=readonly " ]
  [ "${lines[3]}" = "tofu -chdir=$MISE_PROJECT_ROOT/modules/a test " ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "tofu:test stops at the first failing suite" {
  MISE_PROJECT_ROOT=$(make_repository modules/a/tests/unit.tftest.hcl modules/b/tests/unit.tftest.hcl)
  printf '#!/usr/bin/env bash\nprintf "tofu %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *" test" ]]\n' >"$stubs/tofu"
  run "$root_directory/.mise/tasks/tofu/test.sh"
  [ "$status" -ne 0 ]
  ! grep -q "modules/b" "$CALLS"
}

@test "tofu:test runs nothing when no suite exists" {
  MISE_PROJECT_ROOT=$(make_repository modules/b/tests/unit.bats)
  run "$root_directory/.mise/tasks/tofu/test.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}

@test "cilium:conformance records flows through a Hubble Relay port-forward, then removes its test workloads" {
  run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -eq 0 ]
  run grep '^cilium ' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]%% |*}" =~ ^"cilium --kubeconfig /state/admin.kubeconfig hubble port-forward --port-forward "([0-9]+)$ ]]
  local port="${BASH_REMATCH[1]}"
  [ "${lines[1]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --log-check-only-test-time --hubble-server localhost:$port --flow-validation disabled" ]
  [ "${lines[2]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup" ]
}

@test "cilium:conformance keeps the test workloads of a failing suite" {
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" == *"hubble port-forward"* ]] && exec nc -l 127.0.0.1 "${@: -1}" >/dev/null\n[[ "$*" != *--log-check-only-test-time* ]]\n' >"$stubs/cilium"
  run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -ne 0 ]
  grep -q -- --log-check-only-test-time "$CALLS"
  ! grep -q -- --cleanup "$CALLS"
}

@test "cilium:conformance stops before the suite when the Hubble Relay port-forward exits" {
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *"hubble port-forward"* ]]\n' >"$stubs/cilium"
  run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the process that should listen on local port"*"exited"* ]]
  ! grep -q ' connectivity test' "$CALLS"
}

@test "every traffic probe image is pinned by digest" {
  run grep -h 'image:' "$root_directory"/.mise/traffic/*.yaml
  [ "${#lines[@]}" -gt 0 ]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ image:\ [^\ ]+:[^\ ]+@sha256:[0-9a-f]{64}$ ]] || fail "not pinned by digest: $line"
  done
}

traffic_directory_of_local() {
  printf '%s\n' "$FIRMAMENT_STATE_HOME/environment/local/traffic"
}

@test "cilium:traffic-start deploys fortio, snapshots the agent, sets up conn-disrupt, then starts the fortio run" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -eq 0 ]
  local traffic
  traffic=$(traffic_directory_of_local)
  [[ "$output" == *"Traffic is running (fortio run 3). Measure it with: mise run cilium:traffic-check local"* ]]
  run grep -E '^(kubectl|cilium) ' "$CALLS"
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig apply -f $MISE_PROJECT_ROOT/.mise/traffic/fortio.yaml "* ]]
  [[ "${lines[1]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe rollout status deployment/fortio-server deployment/fortio-client --timeout=3m "* ]]
  [[ "${lines[2]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  [[ "${lines[3]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --conn-disrupt-test-setup --include-conn-disrupt-test --conn-disrupt-client-timeout 1s --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[4]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe exec deployment/fortio-client -- fortio curl -quiet -timeout 30s -payload "*" http://localhost:8080/fortio/rest/run "* ]]
  [[ "${lines[5]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/status?runid=3 "* ]]
  local payload
  payload=$(sed -n 's/.* -payload \({.*}\) http:.*/\1/p' <<<"${lines[4]}")
  [ "$(jq -c . <<<"$payload")" = '{"url":"http://fortio-server:8080/echo","qps":"100","t":"on","timeout":"1s","connection-reuse":"1:1","c":"4","async":"on","save":"on"}' ]
  [ "$(cat "$traffic/fortio-run")" = 3 ]
  grep -q uid-agent "$traffic/agent-before"
  [[ "$(cat "$traffic/running-since")" =~ ^[0-9]+$ ]]
}

@test "cilium:traffic-start replaces the state a stopped run left behind" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  mkdir -p "$(traffic_directory_of_local)"
  : >"$(traffic_directory_of_local)/result.json"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -eq 0 ]
  [ ! -e "$(traffic_directory_of_local)/result.json" ]
}

@test "cilium:traffic-start fails when fortio does not start a run" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  export FORTIO_RUN="$BATS_TEST_TMPDIR/run.json"
  printf '{"message":"bad url","exception":"x"}\n' >"$FORTIO_RUN"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *'fortio did not start a run; it replied: {"message":"bad url","exception":"x"}'* ]]
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

# Leaves the state cilium:traffic-start writes: fortio run 3, running since
# 5 s ago, and an agent pod with UID uid-before. $PODS lists the agent pod
# cilium:traffic-check finds, the same one unless a test changes it.
started_traffic() {
  local traffic
  traffic=$(traffic_directory_of_local)
  mkdir -p "$traffic"
  printf '3\n' >"$traffic/fortio-run"
  printf '%s\n' "$(($(date +%s) - 5))" >"$traffic/running-since"
  pods uid-before | jq -r '.items[] | [.metadata.namespace + "/" + .metadata.name, .metadata.uid, "containerd://1", 0] | @tsv' >"$traffic/agent-before"
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-before >"$PODS"
  export FORTIO_RESULT="$BATS_TEST_TMPDIR/result.json"
  fortio_result '.' >"$FORTIO_RESULT"
}

# Prints the live fortio result, reshaped into a run that started 10 s ago,
# ran 20 s and answered all 2000 requests with 200, then filtered through
# the given jq program.
fortio_result() {
  jq "$1" <(jq '.StartTime = (now - 10 | strftime("%Y-%m-%dT%H:%M:%S.123456789Z"))
    | .ActualDuration = 20000000000 | .DurationHistogram.Count = 2000 | .RetCodes = {"200": 2000}' \
    "$FORTIO_REPLIES/result.json")
}

@test "cilium:traffic-check fails when no traffic run started, before measuring anything" {
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"no traffic run started for environment 'local'; start one with: mise run cilium:traffic-start local"* ]]
  ! grep -Eq '^(cilium|kubectl) ' "$CALLS"
}

@test "cilium:traffic-check passes traffic that crossed an agent restart, then removes the workloads and state" {
  started_traffic
  pods uid-after >"$PODS"
  local traffic
  traffic=$(traffic_directory_of_local)
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"fortio: 2000 of 2000 requests answered 200 over 20s; the slowest took 1006 ms"* ]]
  [ "${lines[-1]}" = "traffic held across the Cilium agent restart" ]
  run grep -E '^(kubectl|cilium) ' "$CALLS"
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  [[ "${lines[1]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --include-conn-disrupt-test --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[2]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/stop?runid=3&wait=on "* ]]
  [[ "${lines[3]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/data/2026-09-25-130545_3.json "* ]]
  [[ "${lines[4]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete namespace traffic-probe "* ]]
  [[ "${lines[5]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup "* ]]
  [ ! -e "$traffic" ]
}

@test "cilium:traffic-check passes but says continuity was not exercised when the agent kept running" {
  started_traffic
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "the Cilium agent was not restarted, so traffic continuity was not exercised" ]
}

# Runs cilium:traffic-check, expects it to fail with the given message, and
# checks that the workloads and the state are kept for inspection.
expect_traffic_check_failure() {
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"$1"* ]] || fail "missing '$1' in: $output"
  [[ "$output" == *"are kept for inspection"* ]]
  ! grep -q 'delete namespace traffic-probe' "$CALLS"
  ! grep -q -- '--cleanup' "$CALLS"
  [ -f "$(traffic_directory_of_local)/fortio-run" ]
}

@test "cilium:traffic-check fails when a conn-disrupt connection broke, and still stops the fortio run" {
  started_traffic
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--include-conn-disrupt-test* ]]\n' >"$stubs/cilium"
  expect_traffic_check_failure "conn-disrupt: a connection held open since cilium:traffic-start broke"
  grep -q '/fortio/rest/stop?runid=3&wait=on' "$CALLS"
}

@test "cilium:traffic-check fails when any fortio request failed, naming the return codes" {
  started_traffic
  fortio_result '.RetCodes = {"-1": 28, "200": 1972}' >"$FORTIO_RESULT"
  expect_traffic_check_failure 'fortio: 28 of 2000 requests failed (return codes {"-1":28,"200":1972})'
}

@test "cilium:traffic-check fails when the fortio run started after traffic-start saw it running" {
  started_traffic
  fortio_result '.StartTime = (now + 60 | strftime("%Y-%m-%dT%H:%M:%SZ"))' >"$FORTIO_RESULT"
  expect_traffic_check_failure "after cilium:traffic-start saw it running"
}

@test "cilium:traffic-check fails when the fortio run ended before the check began" {
  started_traffic
  fortio_result '.ActualDuration = 2000000000 | .DurationHistogram.Count = 200 | .RetCodes = {"200": 200}' >"$FORTIO_RESULT"
  expect_traffic_check_failure "before cilium:traffic-check began"
}

@test "cilium:traffic-check fails when fortio sent under 90% of the requests asked for" {
  started_traffic
  fortio_result '.DurationHistogram.Count = 1700 | .RetCodes = {"200": 1700}' >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio: 1700 requests in 20s is under 90% of the 100 a second asked for"
}

@test "cilium:traffic-check fails when fortio stops the run without a saved result" {
  started_traffic
  export FORTIO_STOP="$BATS_TEST_TMPDIR/stop.json"
  printf '{"message":"stopping","RunID":3,"Count":0,"ResultID":"","ResultURL":""}\n' >"$FORTIO_STOP"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio did not stop run 3 with a saved result"* ]]
  ! grep -q -- '--cleanup' "$CALLS"
}

@test "cilium:traffic-check fails on a fortio result without the fields it measures" {
  started_traffic
  fortio_result 'del(.RetCodes)' >"$FORTIO_RESULT"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio result 2026-09-25-130545_3 lacks StartTime, ActualDuration, RetCodes or DurationHistogram"* ]]
  ! grep -q -- '--cleanup' "$CALLS"
}

# Records each mise call with the branch Flux would follow. FAIL_CALL fails
# the matching call; ON_CALL runs ON_CALL_RUN just before the matching call.
e2e_mise_stub() {
  cat >"$stubs/mise" <<'STUB'
#!/usr/bin/env bash
printf 'mise %s | branch=%s\n' "$*" "${FIRMAMENT_GIT_BRANCH:-}" >>"$CALLS"
if [[ "$*" == "${ON_CALL:-}" ]]; then
  eval "$ON_CALL_RUN"
fi
[[ "$*" != "${FAIL_CALL:-}" ]]
STUB
  chmod +x "$stubs/mise"
}

# A pushed checkout of feature/test with one environment, as env:e2e needs.
e2e_repository() {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environment/local/main.tf "$@")
  export MISE_PROJECT_ROOT
}

# Records each chainsaw call with the KUBECONFIG it runs under.
record_chainsaw_kubeconfig() {
  printf '#!/usr/bin/env bash\nprintf "chainsaw %%s | KUBECONFIG=%%s\\n" "$*" "$KUBECONFIG" >>"$CALLS"\n' >"$stubs/chainsaw"
}

# A pushed checkout of feature/test whose main branch, on origin, already
# hands Cilium to Flux and lists the workloads an upgrade must leave running.
upgrade_repository() {
  e2e_repository components/cni-cilium/helmrelease.yaml environment/local/tests/upgrade-unaffected
  printf 'kube-system k8s-app=kube-dns\n' >"$MISE_PROJECT_ROOT/environment/local/tests/upgrade-unaffected"
  commit_and_push "$MISE_PROJECT_ROOT" feature/test unaffected
  commit_and_push "$MISE_PROJECT_ROOT" main baseline
  git -C "$MISE_PROJECT_ROOT" reset -q --hard origin/feature/test
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-steady >"$PODS"
}

# Prints a one-pod list whose pod has the given UID, as kubectl get pods -o json.
pods() {
  jq -n --arg uid "$1" '{items: [{metadata: {namespace: "kube-system", name: "coredns-1", uid: $uid},
    status: {containerStatuses: [{containerID: "containerd://1", restartCount: 0}]}}]}'
}

mise_calls() {
  grep '^mise ' "$CALLS" | sed 's/ | branch=.*//'
}

@test "env:e2e rebuilds the cluster from scratch, runs every live check, and destroys it" {
  e2e_mise_stub
  e2e_repository
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  tested=$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)
  [[ "$output" == *"env:e2e passed for local at $tested; the cluster is destroyed."* ]]
  [[ "$output" == *"OrbStack: "* && "$output" == *"kernel: "* ]]
  grep -q '^orb -m firmament uname -r ' "$CALLS"
  run mise_calls
  [ "$output" = "mise run --yes env:destroy local
mise run env:apply local
mise run verify local
mise run cilium:conformance local
mise run --yes env:destroy local" ]
}

@test "env:e2e stops at the first failing step and leaves the cluster for inspection" {
  e2e_mise_stub
  e2e_repository
  FAIL_CALL="run verify local" run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: mise run verify local"* ]]
  [[ "$output" == *"Remove it with: mise run --yes env:destroy local"* ]]
  [ "$(mise_calls | tail -1)" = "mise run verify local" ]
  [ "$(mise_calls | wc -l)" -eq 3 ]
}

@test "env:e2e refuses a working tree with changes Flux cannot see" {
  e2e_mise_stub
  e2e_repository
  : >"$MISE_PROJECT_ROOT/untracked.txt"
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the working tree has changes Flux cannot see"* ]]
  ! grep -q '^mise ' "$CALLS"
}

@test "env:e2e refuses a branch that is not on origin" {
  e2e_mise_stub
  e2e_repository
  FIRMAMENT_GIT_BRANCH=feature/unpushed run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/unpushed does not exist; push the branch first"* ]]
  ! grep -q '^mise ' "$CALLS"
}

@test "env:e2e refuses a commit that is not pushed" {
  e2e_mise_stub
  e2e_repository
  git -C "$MISE_PROJECT_ROOT" -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m local
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not origin/feature/test"*"push or pull first"* ]]
  ! grep -q '^mise ' "$CALLS"
}

@test "env:e2e refuses a branch name the bootstrap shell would misread" {
  e2e_mise_stub
  e2e_repository
  FIRMAMENT_GIT_BRANCH='main;touch x' run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid branch name 'main;touch x'"* ]]
  ! grep -q '^mise ' "$CALLS"
}

@test "env:e2e fails when origin moves while it runs, and keeps the cluster" {
  e2e_mise_stub
  e2e_repository
  export ON_CALL="run cilium:conformance local"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved && git -C "$MISE_PROJECT_ROOT" push -q origin HEAD:refs/heads/feature/test'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/test moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance local" ]
}

@test "env:e2e --from-branch applies the baseline branch, verifies it, then applies the checkout over it" {
  e2e_mise_stub
  upgrade_repository
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"Baseline: origin/main at $(git -C "$MISE_PROJECT_ROOT" rev-parse origin/main)"* ]]
  run grep '^mise ' "$CALLS"
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = "mise run --yes env:destroy local | branch=feature/test" ]
  [[ "${lines[1]}" == "mise --cd "*"/baseline run env:apply local | branch=main" ]]
  [[ "${lines[2]}" == "mise --cd "*"/baseline run env:verify local | branch=main" ]]
  [ "${lines[3]}" = "mise run env:apply local | branch=feature/test" ]
  [ "${lines[4]}" = "mise run verify local | branch=feature/test" ]
  [ "${lines[5]}" = "mise run cilium:conformance local | branch=feature/test" ]
  [ "${lines[6]}" = "mise run --yes env:destroy local | branch=feature/test" ]
  ! git -C "$MISE_PROJECT_ROOT" worktree list | grep -q /baseline
}

@test "env:e2e --from-branch fails when the switch replaces a workload it should not touch" {
  e2e_mise_stub
  upgrade_repository
  pods uid-before >"$PODS"
  export ON_CALL="run env:apply local"
  export ON_CALL_RUN='pods uid-after >"$PODS"'
  export -f pods
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the upgrade replaced or restarted workloads it should not touch"* ]]
  [[ "$output" == *"uid-before"*"uid-after"* ]]
  [ "$(mise_calls | tail -1)" = "mise run verify local" ]
}

@test "env:e2e --from-branch fails when a listed workload selects no pod" {
  e2e_mise_stub
  upgrade_repository
  printf '{"items": []}' >"$PODS"
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"kube-system k8s-app=kube-dns selects no pod"* ]]
  [[ "$output" == *"env:e2e stopped at: snapshot_workloads"* ]]
}

@test "env:e2e --from-branch records the platform versions right after the baseline apply" {
  e2e_mise_stub
  upgrade_repository
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [ "$(grep -c '^orb -m firmament uname -r ' "$CALLS")" -eq 1 ]
  [[ "$output" == *"OrbStack: "*"kernel: "* ]]
}

@test "env:e2e --from-branch refuses the checked-out branch as its own baseline" {
  e2e_mise_stub
  upgrade_repository
  usage_from_branch=feature/test run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from-branch names the checked-out branch feature/test"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e fails when it cannot fetch origin at the end, and keeps the cluster" {
  e2e_mise_stub
  e2e_repository
  export ON_CALL="run cilium:conformance local"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: remote_tip_unchanged feature/test"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance local" ]
}

@test "env:e2e --from-branch refuses a baseline that is not merged into main" {
  e2e_mise_stub
  upgrade_repository
  git -C "$MISE_PROJECT_ROOT" checkout -q -b feature/unmerged
  commit_and_push "$MISE_PROJECT_ROOT" feature/unmerged unmerged
  git -C "$MISE_PROJECT_ROOT" checkout -q feature/test
  usage_from_branch=feature/unmerged run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/unmerged at "*" is not merged into origin/main"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e --from-branch refuses a baseline that does not hand Cilium to Flux" {
  e2e_mise_stub
  e2e_repository environment/local/tests/upgrade-unaffected
  commit_and_push "$MISE_PROJECT_ROOT" main k0s-baseline
  git -C "$MISE_PROJECT_ROOT" reset -q --hard origin/feature/test
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main at "*" does not hand Cilium to Flux"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e --from-branch refuses a baseline name the bootstrap shell would misread" {
  e2e_mise_stub
  e2e_repository
  usage_from_branch='main;touch x' run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid branch name 'main;touch x'"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e --from-branch refuses a baseline branch that is not on origin" {
  e2e_mise_stub
  e2e_repository
  usage_from_branch=absent run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/absent does not exist; push the branch first"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e --from-branch fails when the baseline branch moves while it runs" {
  e2e_mise_stub
  upgrade_repository
  export ON_CALL="run cilium:conformance local"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" push -q --force origin HEAD:refs/heads/main'
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance local" ]
  ! git -C "$MISE_PROJECT_ROOT" worktree list | grep -q /baseline
}

@test "env:verify waits for Flux to apply origin's tip, then checks it" {
  record_chainsaw_kubeconfig
  e2e_repository environment/local/tests/cluster/chainsaw-test.yaml
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -eq 0 ]
  revision="refs/heads/feature/test@sha1:$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)"
  run grep -E '^(kubectl .* wait kustomization|chainsaw )' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait kustomization/flux-system --for=jsonpath={.status.lastAppliedRevision}=$revision --timeout=10m" ]
  [ "${lines[1]}" = "chainsaw test --test-dir $MISE_PROJECT_ROOT/environment/local/tests/cluster --set-string flux_revision=$revision | KUBECONFIG=/state/admin.kubeconfig" ]
}

@test "env:verify fails for an environment without a cluster suite" {
  MISE_PROJECT_ROOT=$(make_repository environment/bare/main.tf)
  run_task "$root_directory/.mise/tasks/env/verify.sh" bare
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'bare' has no cluster suite at $MISE_PROJECT_ROOT/environment/bare/tests/cluster"* ]]
  [ ! -e "$CALLS" ]
}

# Builds a stand-in repository with one chainsaw suite for environment "x":
# the local suite, edited by the given yq expression. Uses the real chainsaw.
edited_suite_repository() {
  local repository suite=environment/x/tests/cluster/chainsaw-test.yaml
  repository=$(make_repository "$suite")
  yq "$1" "$root_directory/environment/local/tests/cluster/chainsaw-test.yaml" >"$repository/$suite"
  rm "$stubs/chainsaw"
  printf '%s\n' "$repository"
}

@test "chainsaw:lint accepts every environment's cluster suite" {
  rm "$stubs/chainsaw"
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 0 ]
}

@test "chainsaw:lint accepts diagnostics that only read the cluster on failure" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.spec.steps[0].catch = [{"podLogs": {"selector": "k8s-app=cilium"}}, {"events": {}}]')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 0 ]
}

@test "chainsaw:lint rejects an operation that changes the cluster" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.spec.steps[0].try[1] = {"update": .spec.steps[0].try[1].error}')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"try may not run update"* ]]
}

@test "chainsaw:lint rejects a namespace chainsaw would create" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.spec.namespace = "e2e"')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"spec.namespace must be kube-system, not e2e"* ]]
}

@test "chainsaw:lint rejects a suite without a namespace" {
  MISE_PROJECT_ROOT=$(edited_suite_repository 'del(.spec.namespace)')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"spec.namespace must be kube-system, not unset"* ]]
}

@test "chainsaw:lint rejects a script run on failure" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.spec.steps[0].catch = [{"script": {"content": "kubectl get pods"}}]')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"catch and finally may not run script"* ]]
}

@test "chainsaw:lint rejects a step that pulls operations from elsewhere" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.spec.steps[0] = {"name": "shared steps", "use": {"template": "steps.yaml"}}')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"step may not declare use"* ]]
}

@test "chainsaw:lint rejects a suite that is not a valid chainsaw test" {
  MISE_PROJECT_ROOT=$(edited_suite_repository '.kind = "Tset"')
  run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid chainsaw test"* ]]
}

@test "lists mise.toml tasks in alphabetical order" {
  run bash -c "grep -oE '^\[tasks\.[^]]+\]' '$root_directory/mise.toml' | tr -d '\"[]'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(LC_ALL=C sort <<<"$output")" ]
}

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

@test "flux:lint accepts every environment's Flux build" {
  rm "$stubs/kubectl"
  run "$root_directory/.mise/tasks/flux/lint.sh"
  [ "$status" -eq 0 ]
}

@test "flux:lint fails when there is no Flux build to check" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository environment/local/main.tf)
  run "$MISE_PROJECT_ROOT/.mise/tasks/flux/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no environment/*/flux build to validate"* ]]
}

@test "flux:lint validates without the network, against the vendored schemas" {
  rm "$stubs/kubectl"
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 run "$root_directory/.mise/tasks/flux/lint.sh"
  [ "$status" -eq 0 ]
}

@test "flux:lint names flux:schemas when a kind has no vendored schema" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/environment/new/flux"
  cat >"$MISE_PROJECT_ROOT/environment/new/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/environment/new/flux/secret.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: demo
  namespace: flux-system
YAML
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 run "$MISE_PROJECT_ROOT/.mise/tasks/flux/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"run mise run flux:schemas"* ]]
}

@test "flux:schemas fetches one schema per rendered kind from the pinned catalog commit" {
  rm "$stubs/kubectl"
  cat >"$stubs/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
while (($#)); do
  if [[ "$1" == -o ]]; then printf '{}' >"$2"; fi
  shift
done
STUB
  chmod +x "$stubs/curl"
  repository="$BATS_TEST_TMPDIR/schemas-repository"
  mkdir -p "$repository/.mise"
  cp -R "$root_directory/.mise/tasks" "$root_directory/.mise/lib.sh" "$root_directory/.mise/flux-test-values.env" "$repository/.mise/"
  cp -R "$root_directory/environment" "$root_directory/components" "$repository/"
  MISE_PROJECT_ROOT="$repository" run "$repository/.mise/tasks/flux/schemas.sh"
  [ "$status" -eq 0 ]
  run grep -c '^curl -fsSL https://raw.githubusercontent.com/fluxcd/flux-schema/88c74c0294aaf472a8df920f92a2f28811a47d72/catalog/latest/' "$CALLS"
  [ "$output" = 4 ]
  [ -f "$repository/.mise/flux-schemas/core/configmap_v1.json" ]
  [ -f "$repository/.mise/flux-schemas/helm.toolkit.fluxcd.io/helmrelease_v2.json" ]
}

@test "flux:schemas keeps the vendored schemas when a download fails" {
  rm "$stubs/kubectl"
  printf '#!/usr/bin/env bash\nexit 22\n' >"$stubs/curl"
  chmod +x "$stubs/curl"
  repository="$BATS_TEST_TMPDIR/schemas-repository"
  mkdir -p "$repository/.mise"
  cp -R "$root_directory/.mise/tasks" "$root_directory/.mise/lib.sh" "$root_directory/.mise/flux-test-values.env" "$root_directory/.mise/flux-schemas" "$repository/.mise/"
  cp -R "$root_directory/environment" "$root_directory/components" "$repository/"
  MISE_PROJECT_ROOT="$repository" run "$repository/.mise/tasks/flux/schemas.sh"
  [ "$status" -ne 0 ]
  diff -r "$root_directory/.mise/flux-schemas" "$repository/.mise/flux-schemas"
}

@test "flux:lint rejects a Flux build that breaks its schema" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/environment/bad/flux"
  cat >"$MISE_PROJECT_ROOT/environment/bad/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/environment/bad/flux/helmrelease.yaml" <<'YAML'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: demo
  namespace: flux-system
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: demo
  notAField: true
YAML
  run "$MISE_PROJECT_ROOT/.mise/tasks/flux/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment/bad/flux: the rendered Flux build is not valid"* ]]
}

@test "flux:lint rejects a Flux build with a variable no runtime value sets" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/environment/bad/flux"
  cat >"$MISE_PROJECT_ROOT/environment/bad/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/environment/bad/flux/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: flux-system
data:
  value: ${not_a_runtime_value}
YAML
  run "$MISE_PROJECT_ROOT/.mise/tasks/flux/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'variable not set (strict mode): "not_a_runtime_value"'* ]]
}

# Runs orb:capture-stall for the machine "demo" without a terminal, with the
# host network tools replaced by recording stand-ins, and prints the capture
# directory.
run_capture_stall() {
  local tool
  for tool in arp dscacheutil route lsof; do
    [ -e "$stubs/$tool" ] || stub "$tool"
  done
  usage_machine=demo run "$root_directory/.mise/tasks/orb/capture-stall.sh" </dev/null
}

@test "orb:capture-stall records each command, its output and its exit status" {
  run_capture_stall
  [ "$status" -eq 0 ] || fail "$output"
  local directory
  directory=$(printf '%s\n' "$FIRMAMENT_STATE_HOME"/stalls/*)
  [[ "$output" == *"Captured in $directory"* ]]
  [ "$(head -1 "$directory/host-route.txt")" = '$ route -n get demo.orb.local' ]
  [ "$(tail -1 "$directory/host-route.txt")" = 'exit 0' ]
  grep -qx 'orb -m demo -u root ss -tnp | state= branch=' "$CALLS"
  grep -qx 'orb -m demo -u root journalctl -u ssh --since -1h --no-pager | state= branch=' "$CALLS"
  grep -qx 'lsof -nP -iTCP:32222 | state= branch=' "$CALLS"
  ! grep -q '^tofu ' "$CALLS" || fail "read tofu state, which a stalled apply has not written: $(cat "$CALLS")"
}

@test "orb:capture-stall keeps capturing after a command fails" {
  printf '#!/usr/bin/env bash\nexit 3\n' >"$stubs/arp"
  chmod +x "$stubs/arp"
  run_capture_stall
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(tail -1 "$FIRMAMENT_STATE_HOME"/stalls/*/host-arp.txt)" = 'exit 3' ]
  grep -q '^orb -m demo -u root journalctl ' "$CALLS"
}

@test "orb:capture-stall never uploads an orb report no one can review" {
  run_capture_stall
  [ "$status" -eq 0 ] || fail "$output"
  ! grep -q '^orb report' "$CALLS"
  [[ "$output" == *"Skipped orb report: no terminal to review it."* ]]
}
