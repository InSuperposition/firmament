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

# Runs a task script the way mise does, with MISE_ENV naming the environment
# and the state directory mise derives from it.
# cilium:conformance and the UI tasks forward to a random high port, so a
# real forward on a default port does not collide with the tests.
run_task() {
  local script="$1" environment="$2"
  MISE_ENV="$environment" TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/$environment" \
    usage_hubble_port=$((20000 + RANDOM % 20000)) usage_port=$((20000 + RANDOM % 20000)) run "$script"
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
  e2e_repository clusters/singularity/tests/cluster/chainsaw-test.yaml
  # A recorded cluster with a kubeconfig file, so env:doctor checks the API too.
  record_contracts "$BATS_TEST_TMPDIR/admin.kubeconfig"
  : >"$BATS_TEST_TMPDIR/admin.kubeconfig"
  for script in $(environment_scripts); do
    case "$(basename "$script")" in
    # e2e.sh destroys through `mise run`; its own tests check what it runs.
    # The traffic tasks deploy workloads and measure a run started earlier;
    # their own tests below check them.
    apply.sh | destroy.sh | e2e.sh | restart-agent.sh | traffic-start.sh | traffic-check.sh) continue ;;
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
    "$root_directory/.mise/tasks/env/e2e.sh" "$root_directory"/.mise/tasks/cilium/{conformance,restart-agent,traffic-start,traffic-check}.sh; do
    grep -qx 'claim_environment' "$script" || fail "$script changes the environment without claiming it"
  done
}

@test "env:apply refuses an environment another worktree owns, before applying" {
  mkdir -p "$BATS_TEST_TMPDIR/other-worktree" "$FIRMAMENT_STATE_HOME/environments/local"
  printf '%s\n' "$BATS_TEST_TMPDIR/other-worktree" >"$FIRMAMENT_STATE_HOME/environments/local/owner"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to the worktree $BATS_TEST_TMPDIR/other-worktree"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

# Gives the local environment's machine and Kubernetes roots a state file,
# as any applied environment has.
local_state() {
  mkdir -p "$FIRMAMENT_STATE_HOME/environments/local"
  printf '{"version": 4}\n' >"$FIRMAMENT_STATE_HOME/environments/local/machine-orb.tfstate"
  printf '{"version": 4}\n' >"$FIRMAMENT_STATE_HOME/environments/local/kubernetes-k0s.tfstate"
}

@test "orb:destroy refuses an empty state file instead of destroying nothing" {
  mkdir -p "$FIRMAMENT_STATE_HOME/environments/local"
  : >"$FIRMAMENT_STATE_HOME/environments/local/machine-orb.tfstate"
  run_task "$root_directory/.mise/tasks/orb/destroy.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine-orb.tfstate is empty"* ]]
  ! grep -q ' destroy ' "$CALLS" 2>/dev/null || fail "ran destroy against an empty state: $(cat "$CALLS")"
}

@test "env:destroy destroys the Kubernetes root, then the machine root, and leaves the bootstrap root alone" {
  local_state
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  run grep -E '^tofu -chdir=.* (init|destroy) ' "$CALLS"
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == "tofu -chdir=$root_directory/roots/kubernetes-k0s init "* ]]
  [[ "${lines[1]}" == "tofu -chdir=$root_directory/roots/kubernetes-k0s destroy -input=false -auto-approve "* ]]
  [[ "${lines[2]}" == "tofu -chdir=$root_directory/roots/machine-orb init "* ]]
  [[ "${lines[3]}" == "tofu -chdir=$root_directory/roots/machine-orb destroy -input=false -auto-approve "* ]]
  ! grep -q -- 'roots/bootstrap-flux' "$CALLS" || fail "ran tofu in the bootstrap root: $(cat "$CALLS")"
  ! grep -q ' state rm ' "$CALLS" || fail "removed state by hand: $(cat "$CALLS")"
}

@test "env:destroy runs on a fresh machine with no state yet, and destroys nothing" {
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  ! grep -q ' destroy ' "$CALLS" 2>/dev/null || fail "destroyed a root with no state: $(cat "$CALLS")"
}

@test "env:destroy runs from a detached HEAD" {
  unset FIRMAMENT_GIT_BRANCH
  e2e_repository
  git -C "$MISE_PROJECT_ROOT" checkout -q --detach
  local_state
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  grep -q ' destroy -input=false -auto-approve .*branch=main$' "$CALLS"
}

@test "orb:destroy destroys the k0s record before the machine it runs on, and leaves the bootstrap root alone" {
  local_state
  run_task "$root_directory/.mise/tasks/orb/destroy.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^tofu -chdir=.* destroy ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "tofu -chdir=$root_directory/roots/kubernetes-k0s destroy -input=false -auto-approve "* ]]
  [[ "${lines[1]}" == "tofu -chdir=$root_directory/roots/machine-orb destroy -input=false -auto-approve "* ]]
  ! grep -q -- 'roots/bootstrap-flux' "$CALLS" || fail "ran tofu in the bootstrap root: $(cat "$CALLS")"
}

@test "env:apply applies the machine root, then the Kubernetes root, then the bootstrap root, then waits" {
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  local state="$FIRMAMENT_STATE_HOME/environments/local" root i=0
  run grep -E '^(tofu -chdir=.* (init|apply) |cilium )' "$CALLS"
  for root in machine-orb kubernetes-k0s bootstrap-flux; do
    [[ "${lines[i]}" == "tofu -chdir=$root_directory/roots/$root init "*"-backend-config=path=$state/$root.tfstate "* ]] || fail "line $i: ${lines[i]}"
    [[ "${lines[i + 1]}" == "tofu -chdir=$root_directory/roots/$root apply -input=false -auto-approve "* ]] || fail "line $((i + 1)): ${lines[i + 1]}"
    i=$((i + 2))
  done
  [[ "${lines[6]}" == "cilium --kubeconfig /state/admin.kubeconfig status"* ]]
}

@test "env:plan plans every root once the environment records a machine and a cluster" {
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  local root
  for root in machine-orb kubernetes-k0s bootstrap-flux; do
    grep -q "^tofu -chdir=$root_directory/roots/$root plan -input=false " "$CALLS" || fail "$root not planned"
  done
}

@test "env:plan skips the bootstrap root while the environment records no cluster" {
  forget_contract cluster-access.yaml
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"No cluster recorded yet, so the bootstrap is not planned"* ]]
  grep -q "^tofu -chdir=$root_directory/roots/kubernetes-k0s plan -input=false " "$CALLS"
  ! grep -q -- 'roots/bootstrap-flux' "$CALLS" || fail "ran tofu in the bootstrap root: $(cat "$CALLS")"
}

@test "env:plan plans only the machine root while the environment records no machine" {
  forget_contract machine-hosts.yaml
  forget_contract cluster-access.yaml
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"No machine recorded yet, so k0s and the bootstrap are not planned"* ]]
  grep -q "^tofu -chdir=$root_directory/roots/machine-orb plan -input=false " "$CALLS"
  ! grep -qE -- 'roots/(kubernetes-k0s|bootstrap-flux)' "$CALLS" || fail "planned a later root: $(cat "$CALLS")"
}

@test "env:apply refuses a recorded cluster that cannot say whether k0s installs charts" {
  K0S_CHARTS_ERROR="Unable to connect to the server: dial tcp: i/o timeout" run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell whether k0s installs Helm charts"*"i/o timeout"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply refuses a contract file it cannot read" {
  printf 'kubeconfig_path: [unclosed\n' >"$FIRMAMENT_STATE_HOME/environments/local/cluster-access.yaml"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply applies a destroyed environment without asking it for k0s charts" {
  forget_contract machine-hosts.yaml
  forget_contract cluster-access.yaml
  # The stub tofu writes no contract, so the wait that follows the applies
  # fails, and only there.
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' has no .kubeconfig_path in cluster-access.yaml"* ]]
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
  ! grep -q 'get charts.helm.k0sproject.io' "$CALLS"
}

@test "env:apply applies a cluster where k0s installs no charts" {
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ]
  grep -q 'get charts.helm.k0sproject.io' "$CALLS"
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
}

@test "env:apply asks no cluster for charts while the machine-hosts contract is missing" {
  forget_contract machine-hosts.yaml
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  ! grep -q 'get charts.helm.k0sproject.io' "$CALLS" || fail "asked a destroyed cluster for charts"
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
}

@test "env:apply refuses a cluster whose Helm charts k0s still installs" {
  K0S_CHARTS=chart.helm.k0sproject.io/k0s-addon-chart-cilium run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0s still installs Helm charts on this cluster"*"k0s-addon-chart-cilium"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "k0s:apply applies the Kubernetes root, then waits for the node" {
  NODES=node/firmament run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ]
  run grep -nE '^(tofu .* apply |kubectl |cilium )' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"tofu -chdir=$root_directory/roots/kubernetes-k0s apply -input=false -auto-approve "* ]]
  [[ "${lines[1]}" == *"kubectl --kubeconfig /state/admin.kubeconfig get nodes -o name "* ]]
}

@test "verify runs every *:verify task, one at a time, env:verify first" {
  run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%% |*}" = "mise run env:verify" ]
  [ "${lines[1]%% |*}" = "mise run a:verify" ]
  [ "${lines[2]%% |*}" = "mise run k0s:verify" ]
}

@test "verify --only runs the environment's own tasks and the chosen packages' tasks" {
  TASKS="cilium:verify env:verify flux:verify k0s:verify" usage_only=cilium run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%% |*}" = "mise run env:verify --only cilium" ]
  [ "${lines[1]%% |*}" = "mise run cilium:verify" ]
  [ "${lines[2]%% |*}" = "mise run k0s:verify" ]
}

@test "verify --changed checks the packages the branch changed, plus the environment" {
  TASKS="cilium:verify env:verify flux:verify k0s:verify" usage_changed=true run_changed "$root_directory/.mise/tasks/verify.sh" packages/flux/fluxinstance.yaml
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%% |*}" = "mise run env:verify --only flux" ]
  [ "${lines[1]%% |*}" = "mise run flux:verify" ]
  [ "${lines[2]%% |*}" = "mise run k0s:verify" ]
}

@test "conformance --changed runs nothing when no package changed" {
  TASKS="cilium:conformance" usage_changed=true run_changed "$root_directory/.mise/tasks/conformance.sh" README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"No packages changed, so no conformance tests run"* ]]
  [ ! -e "$CALLS" ]
}

@test "verify refuses a package the environment does not deploy, before running any task" {
  usage_only=cilium,nope run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown package 'nope' for environment 'local'; choose from: cilium flux"* ]]
  [ ! -e "$CALLS" ]
}

@test "every package is named <tool>[-<concern>], and none is named none" {
  local package
  for package in "$root_directory"/packages/*/; do
    package="${package%/}"
    package="${package##*/}"
    [[ "$package" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "$package is not named <tool>[-<concern>]"
    [[ "$package" != none ]] || fail "no package may be named none; it means no package"
  done
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

@test "cilium:restart-agent restarts the agent DaemonSet, then waits for the rollout and for Cilium" {
  run_task "$root_directory/.mise/tasks/cilium/restart-agent.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^(kubectl|helm|cilium) ' "$CALLS"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system rollout restart daemonset/cilium "* ]]
  [[ "${lines[1]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system rollout status daemonset/cilium --timeout=10m "* ]]
  [[ "${lines[2]}" == "cilium --kubeconfig /state/admin.kubeconfig status --wait --interactive=false "* ]]
}

@test "tofu:test initializes and tests each suite directory, and never applies" {
  MISE_PROJECT_ROOT=$(make_repository modules/a/tests/unit.tftest.hcl roots/r/tests/wiring.tftest.hcl)
  run "$root_directory/.mise/tasks/tofu/test.sh"
  [ "$status" -eq 0 ]
  run cut -d"|" -f1 "$CALLS"
  [ "${lines[0]}" = "tofu -chdir=$MISE_PROJECT_ROOT/modules/a init -backend=false -input=false -reconfigure -lockfile=readonly " ]
  [ "${lines[1]}" = "tofu -chdir=$MISE_PROJECT_ROOT/modules/a test " ]
  [ "${lines[2]}" = "tofu -chdir=$MISE_PROJECT_ROOT/roots/r init -backend=false -input=false -reconfigure -lockfile=readonly " ]
  [ "${lines[3]}" = "tofu -chdir=$MISE_PROJECT_ROOT/roots/r test " ]
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
  [ "${lines[1]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --log-check-only-test-time --hubble-server localhost:$port --flow-validation disabled --test-concurrency 3" ]
  [ "${lines[2]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup --test-concurrency 3" ]
}

@test "cilium:conformance runs and cleans up the suite across the namespaces --test-concurrency names" {
  usage_test_concurrency=5 run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -eq 0 ]
  [ "$(grep -c -- ' connectivity test .*--test-concurrency 5 |' "$CALLS")" -eq 2 ]
}

@test "cilium:conformance refuses a --test-concurrency that is not a whole number of 1 or more, before calling any tool" {
  local count
  for count in 0 -1 two 1.5 03; do
    rm -f "$CALLS"
    usage_test_concurrency=$count run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
    [ "$status" -ne 0 ] || fail "accepted $count"
    [[ "$output" == *"--test-concurrency must be a whole number of 1 or more, not '$count'"* ]] || fail "$count: $output"
    [ ! -e "$CALLS" ] || fail "$count: called $(cat "$CALLS")"
  done
}

@test "cilium:observe follows flows through a Relay port-forward on a free random port" {
  run_task "$root_directory/.mise/tasks/cilium/observe.sh" local
  [ "$status" -eq 0 ]
  [ "$(grep '^hubble ' "$CALLS" | cut -d'|' -f1)" = "hubble observe --kubeconfig /state/admin.kubeconfig --port-forward --port-forward-port 0 --follow " ]
}

@test "cilium:ui opens the Hubble UI through a port-forward on the given port" {
  TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" usage_port=23456 run "$root_directory/.mise/tasks/cilium/ui.sh"
  [ "$status" -eq 0 ]
  [ "$(grep '^cilium ' "$CALLS" | cut -d'|' -f1)" = "cilium --kubeconfig /state/admin.kubeconfig hubble ui --port-forward 23456 " ]
}

@test "flux:ui forwards the Flux Operator web port, then opens the browser on it" {
  TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" usage_port=23457 run "$root_directory/.mise/tasks/flux/ui.sh"
  [ "$status" -eq 0 ]
  run grep -E '^(kubectl|open) ' "$CALLS"
  [ "${lines[0]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system port-forward svc/flux-operator 23457:9080" ]
  [ "${lines[1]%% |*}" = "open http://localhost:23457" ]
}

@test "flux:ui opens no browser when the port-forward exits" {
  printf '#!/usr/bin/env bash\nprintf "kubectl %%s\\n" "$*" >>"$CALLS"\nexit 1\n' >"$stubs/kubectl"
  TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" usage_port=23458 run "$root_directory/.mise/tasks/flux/ui.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the process that should listen on local port 23458 exited"* ]]
  ! grep -q '^open ' "$CALLS"
}

@test "the UI tasks refuse a busy local port before forwarding anything" {
  local script port=23459
  # -k keeps listening after each connection the busy-port check opens.
  nc -lk 127.0.0.1 "$port" >/dev/null &
  local listener=$!
  source "$root_directory/.mise/lib.sh"
  wait_for_local_port "$listener" "$port" 5
  for script in cilium/ui.sh flux/ui.sh; do
    rm -f "$CALLS"
    TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" usage_port=$port run "$root_directory/.mise/tasks/$script"
    [ "$status" -ne 0 ] || fail "$script accepted a busy port"
    [[ "$output" == *"local port $port is already in use; pick another with --port"* ]] || fail "$script: $output"
    ! grep -Eq '^(cilium|kubectl|open) ' "$CALLS" || fail "$script called $(cat "$CALLS")"
  done
  kill "$listener"
}

@test "cilium:conformance --only runs the tests the chosen packages list" {
  usage_only=cilium run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -eq 0 ]
  run grep ' connectivity test --log-check-only-test-time ' "$CALLS"
  [[ "${lines[0]%% |*}" == *" --test-concurrency 3 --test .*" ]]
}

@test "cilium:conformance --only runs nothing when no chosen package lists a test" {
  usage_only=flux run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"No conformance tests apply to: flux"* ]]
  [ ! -e "$CALLS" ]
}

@test "cilium:conformance refuses an unknown package before calling any tool" {
  usage_only=nope run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown package 'nope' for environment 'local'; choose from: cilium flux"* ]]
  [ ! -e "$CALLS" ]
}

@test "conformance runs every *:conformance task, passing --only on" {
  TASKS="a:verify cilium:conformance other:conformance" usage_only=flux run_task "$root_directory/.mise/tasks/conformance.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "mise run cilium:conformance --only flux" ]
  [ "${lines[1]%% |*}" = "mise run other:conformance --only flux" ]
}

@test "conformance refuses an unknown package before running any task" {
  usage_only=nope run_task "$root_directory/.mise/tasks/conformance.sh" local
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
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
  printf '%s\n' "$FIRMAMENT_STATE_HOME/environments/local/traffic"
}

@test "cilium:traffic-start deploys fortio in a new namespace, sets up conn-disrupt, starts the fortio run, then snapshots the agent" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -eq 0 ]
  local traffic
  traffic=$(traffic_directory_of_local)
  [[ "$output" == *"Traffic is running (fortio run 3). Measure it with: mise run cilium:traffic-check"* ]]
  run grep -E '^(kubectl|cilium) ' "$CALLS"
  [ "${#lines[@]}" -eq 7 ]
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete namespace traffic-probe --ignore-not-found --timeout=2m "* ]]
  [[ "${lines[1]}" == "kubectl --kubeconfig /state/admin.kubeconfig apply -f $MISE_PROJECT_ROOT/.mise/traffic/fortio.yaml "* ]]
  [[ "${lines[2]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe rollout status deployment/fortio-server deployment/fortio-client --timeout=3m "* ]]
  [[ "${lines[3]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --conn-disrupt-test-setup --include-conn-disrupt-test --conn-disrupt-client-timeout 1s --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[4]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe exec deployment/fortio-client -- fortio curl -quiet -timeout 30s -payload "*" http://localhost:8080/fortio/rest/run "* ]]
  [[ "${lines[5]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/status?runid=3 "* ]]
  [[ "${lines[6]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  local payload
  payload=$(sed -n 's/.* -payload \({.*}\) http:.*/\1/p' <<<"${lines[4]}")
  [ "$(jq -c . <<<"$payload")" = '{"url":"http://fortio-server:8080/echo","qps":"100","t":"on","timeout":"1s","connection-reuse":"1:1","c":"4","async":"on","save":"on"}' ]
  [ "$(cat "$traffic/fortio-run")" = 3 ]
  grep -q uid-agent "$traffic/agent-before"
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
  export FORTIO_RUN="$BATS_TEST_TMPDIR/run.json"
  printf '{"message":"bad url","exception":"x"}\n' >"$FORTIO_RUN"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *'fortio did not start a run; it replied: {"message":"bad url","exception":"x"}'* ]]
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

@test "cilium:traffic-start fails when the fortio run never starts sending" {
  export FORTIO_STATUS="$BATS_TEST_TMPDIR/status.json" FIRMAMENT_FORTIO_START_TIMEOUT=1
  printf '{"Statuses":{"3":{"RunID":3,"State":1}}}\n' >"$FORTIO_STATUS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio run 3 is not running after 1s (state 'pending')"* ]]
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
  grep -q '/fortio/rest/stop?runid=0 ' "$CALLS"
}

@test "cilium:traffic-start stops before starting fortio when the fortio rollout does not finish" {
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
if [[ "$*" == *"rollout status"* ]]; then echo 'error: timed out waiting for the condition' >&2; exit 1; fi
STUB
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out waiting for the condition"* ]]
  ! grep -q '/fortio/rest/run' "$CALLS"
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

@test "cilium:traffic-start refuses a start timeout that is not plain whole seconds, before deploying anything" {
  local timeout
  for timeout in 30s 08 1234567; do
    rm -f "$CALLS"
    FIRMAMENT_FORTIO_START_TIMEOUT=$timeout run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
    [ "$status" -ne 0 ]
    [[ "$output" == *"FIRMAMENT_FORTIO_START_TIMEOUT must be whole seconds, at most 6 digits and without a leading zero, not '$timeout'"* ]]
    [ ! -e "$CALLS" ]
  done
}

@test "cilium:traffic-start stops before starting fortio when the conn-disrupt setup fails" {
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--conn-disrupt-test-setup* ]]\n' >"$stubs/cilium"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  ! grep -q '/fortio/rest/run' "$CALLS"
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

# Leaves the state cilium:traffic-start writes: fortio run 3 and an agent
# pod with UID uid-before. $PODS lists the agent pod cilium:traffic-check
# finds, the same one unless a test changes it.
started_traffic() {
  local traffic
  traffic=$(traffic_directory_of_local)
  mkdir -p "$traffic"
  printf '3\n' >"$traffic/fortio-run"
  pods uid-before | jq -r '.items[] | [.metadata.namespace + "/" + .metadata.name, .metadata.uid, "containerd://1", 0] | @tsv' >"$traffic/agent-before"
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-before >"$PODS"
  export FORTIO_RESULT="$BATS_TEST_TMPDIR/result.json"
  fortio_result '.' >"$FORTIO_RESULT"
}

# Prints the live fortio result, reshaped into a run of 20 s that answered
# all 2000 requests with 200, then filtered through the given jq arguments.
fortio_result() {
  jq "$@" <(jq '.ActualDuration = 20000000000 | .DurationHistogram.Count = 2000 | .RetCodes = {"200": 2000}' \
    "$FORTIO_REPLIES/result.json")
}

@test "cilium:traffic-check fails when no traffic run started, before measuring anything" {
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"no traffic run started for environment 'local'; start one with: mise run cilium:traffic-start"* ]]
  ! grep -Eq '^(cilium|kubectl) ' "$CALLS"
}

@test "cilium:traffic-check fails when the fortio run is no longer running, before measuring anything" {
  started_traffic
  export FORTIO_STATUS="$BATS_TEST_TMPDIR/status.json"
  printf '{"Statuses":null}\n' >"$FORTIO_STATUS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio run 3 is not running (state 'none'), so there is nothing to measure; start a new run with: mise run cilium:traffic-start"* ]]
  ! grep -q '^cilium ' "$CALLS"
  ! grep -q '/fortio/rest/stop' "$CALLS"
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
  [ "${#lines[@]}" -eq 7 ]
  [[ "${lines[0]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/status?runid=3 "* ]]
  [[ "${lines[1]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --include-conn-disrupt-test --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[2]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/stop?runid=3&wait=on "* ]]
  [[ "${lines[3]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  [[ "${lines[4]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/data/2026-09-25-130545_3.json "* ]]
  [[ "${lines[5]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete namespace traffic-probe --timeout=2m "* ]]
  [[ "${lines[6]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup "* ]]
  [ ! -e "$traffic" ]
}

@test "cilium:traffic-check passes but says continuity was not exercised when the agent kept running, then cleans up" {
  started_traffic
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "the Cilium agent was not restarted, so traffic continuity was not exercised" ]
  grep -q 'delete namespace traffic-probe' "$CALLS"
  grep -q -- '--cleanup' "$CALLS"
  [ ! -e "$(traffic_directory_of_local)" ]
}

# Runs cilium:traffic-check, expects it to fail with each given message, and
# checks that the workloads and the state are kept for inspection.
expect_traffic_check_failure() {
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  local message
  for message in "$@"; do
    [[ "$output" == *"$message"* ]] || fail "missing '$message' in: $output"
  done
  [[ "$output" == *"The traffic-probe and cilium-test-1 namespaces and $(traffic_directory_of_local) are kept for inspection"* ]]
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

@test "cilium:traffic-check fails when fortio sent under 90% of the rate the run asked for" {
  started_traffic
  fortio_result '.DurationHistogram.Count = 1700 | .RetCodes = {"200": 1700}' >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio: 1700 requests in 20s is under 90% of the 100 a second asked for"
}

@test "cilium:traffic-check reads the requested rate from the fortio result" {
  started_traffic
  fortio_result '.RequestedQPS = "200"' >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio: 2000 requests in 20s is under 90% of the 200 a second asked for"
}

@test "cilium:traffic-check fails a run under 90% of a fractional requested rate" {
  started_traffic
  fortio_result '.RequestedQPS = "100.5" | .DurationHistogram.Count = 1500 | .RetCodes = {"200": 1500}' >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio: 1500 requests in 20s is under 90% of the 100.5 a second asked for"
}

@test "cilium:traffic-check names the state of a run that is no longer running" {
  started_traffic
  export FORTIO_STATUS="$BATS_TEST_TMPDIR/status.json"
  printf '{"Statuses":{"3":{"RunID":3,"State":4}}}\n' >"$FORTIO_STATUS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio run 3 is not running (state 'stopped')"* ]]
}

@test "cilium:traffic-check reports every problem it finds" {
  started_traffic
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--include-conn-disrupt-test* ]]\n' >"$stubs/cilium"
  fortio_result '.DurationHistogram.Count = 1000 | .RetCodes = {"-1": 10, "200": 990}' >"$FORTIO_RESULT"
  expect_traffic_check_failure "conn-disrupt: a connection held open" "fortio: 10 of 1000 requests failed" "fortio: 1000 requests in 20s is under 90%"
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

@test "cilium:traffic-check fails when fortio does not answer, showing why, and keeps the workloads" {
  started_traffic
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
case "$*" in
  *"/fortio/rest/status"*) cat "$FORTIO_REPLIES/status.json" ;;
  *"/fortio/rest/stop"*) echo 'error: pod fortio-client not found' >&2; exit 1 ;;
  *" get pods "*) cat "$PODS" ;;
esac
STUB
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio did not answer http://localhost:8080/fortio/rest/stop?runid=3&wait=on:"*"error: pod fortio-client not found"* ]]
  ! grep -q 'delete namespace traffic-probe' "$CALLS"
  ! grep -q -- '--cleanup' "$CALLS"
}

@test "cilium:traffic-start fails on a run id that is not a number" {
  export FORTIO_RUN="$BATS_TEST_TMPDIR/run.json"
  printf '{"message":"started","RunID":"3"}\n' >"$FORTIO_RUN"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *'fortio did not start a run'* ]]
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

@test "cilium:traffic-check keeps a broken connection in the report when fortio then fails to stop" {
  started_traffic
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--include-conn-disrupt-test* ]]\n' >"$stubs/cilium"
  export FORTIO_STOP="$BATS_TEST_TMPDIR/stop.json"
  printf '{"message":"stopping","ResultID":""}\n' >"$FORTIO_STOP"
  expect_traffic_check_failure "conn-disrupt: a connection held open since cilium:traffic-start broke" "fortio did not stop run 3 with a saved result"
}

@test "cilium:traffic-check fails and keeps the workloads when fortio does not return the result" {
  started_traffic
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
case "$*" in
  *"/fortio/rest/status"*) cat "$FORTIO_REPLIES/status.json" ;;
  *"/fortio/rest/stop"*) cat "$FORTIO_REPLIES/stop.json" ;;
  *"/fortio/data/"*) echo 'error: connection reset' >&2; exit 1 ;;
  *" get pods "*) cat "$PODS" ;;
esac
STUB
  expect_traffic_check_failure "fortio did not answer http://localhost:8080/fortio/data/2026-09-25-130545_3.json" "fortio did not return result 2026-09-25-130545_3"
}

@test "cilium:traffic-check counts every request as failed when none answered 200" {
  started_traffic
  fortio_result '.RetCodes = {"-1": 2000}' >"$FORTIO_RESULT"
  expect_traffic_check_failure 'fortio: 2000 of 2000 requests failed (return codes {"-1":2000})'
}

@test "cilium:traffic-check never evaluates result text as a bash expression" {
  started_traffic
  local marker="$BATS_TEST_TMPDIR/evaluated"
  fortio_result --arg marker "$marker" '.DurationHistogram.Count = "x[$(touch \($marker))0]"' >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio result 2026-09-25-130545_3 is malformed"
  [ ! -e "$marker" ]
}

@test "cilium:traffic-check gives no verdict and keeps the workloads when an agent snapshot is missing" {
  started_traffic
  rm "$(traffic_directory_of_local)/agent-before"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"a Cilium agent snapshot in $(traffic_directory_of_local) is missing or empty, so there is no verdict"* ]]
  [[ "$output" != *"traffic held"* ]]
  ! grep -q 'delete namespace traffic-probe' "$CALLS"
  ! grep -q -- '--cleanup' "$CALLS"
}

@test "fortio_run_state names every fortio run state and passes unknown numbers through" {
  source "$root_directory/.mise/lib.sh"
  export FORTIO_STATUS="$BATS_TEST_TMPDIR/status.json"
  local state expected
  for state in 0:unknown 1:pending 2:running 3:stopping 4:stopped 9:9 -1:-1 2.5:2.5 '"2"':2; do
    printf '{"Statuses":{"3":{"RunID":3,"State":%s}}}\n' "${state%%:*}" >"$FORTIO_STATUS"
    expected=${state#*:}
    [ "$(fortio_run_state /state/admin.kubeconfig 3)" = "$expected" ] || fail "State ${state%%:*} printed $(fortio_run_state /state/admin.kubeconfig 3), not $expected"
  done
}

@test "cilium:traffic-check refuses a result whose numbers bash could misread or that do not add up" {
  local change
  for change in '.RequestedQPS = "nan"' '.RequestedQPS = "1e400"' '.RequestedQPS = "-5"' \
    '.DurationHistogram.Count = 1e30 | .RetCodes = {"-1": 1e30}' \
    '.RetCodes = {"200": 2000, "-1": 28}' \
    '.DurationHistogram.Count = 0 | .RetCodes = {}' '.ActualDuration = 0'; do
    rm -f "$CALLS"
    started_traffic
    fortio_result "$change" >"$FORTIO_RESULT"
    run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
    [ "$status" -ne 0 ] || fail "$change passed"
    [[ "$output" == *"fortio result 2026-09-25-130545_3 is malformed"* ]] || fail "$change: $output"
    ! grep -q -- '--cleanup' "$CALLS"
  done
}

@test "cilium:traffic-check refuses a result id that is not a plain token, before fetching it" {
  started_traffic
  export FORTIO_STOP="$BATS_TEST_TMPDIR/stop.json"
  printf '{"message":"stopped","ResultID":"../x?y"}\n' >"$FORTIO_STOP"
  expect_traffic_check_failure "fortio did not stop run 3 with a saved result"
  ! grep -q '/fortio/data/' "$CALLS"
}

@test "cilium:traffic-check refuses a recorded run id that is not a fortio run id, before calling fortio" {
  started_traffic
  printf '0&x=1\n' >"$(traffic_directory_of_local)/fortio-run"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds '0&x=1', not a fortio run id"* ]]
  ! grep -q '/fortio/' "$CALLS"
}

@test "cilium:traffic-check keeps the verdict in the failure when cleanup fails" {
  started_traffic
  pods uid-after >"$PODS"
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
case "$*" in
  *"/fortio/rest/status"*) cat "$FORTIO_REPLIES/status.json" ;;
  *"/fortio/rest/stop"*) cat "$FORTIO_REPLIES/stop.json" ;;
  *"/fortio/data/"*) cat "$FORTIO_RESULT" ;;
  *" get pods "*) cat "$PODS" ;;
  *"delete namespace"*) echo 'error: timed out waiting for the condition' >&2; exit 1 ;;
esac
STUB
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"traffic held across the Cilium agent restart, but removing the traffic-probe namespace failed"* ]]
}

@test "cilium:traffic-start stops every fortio run when the reply to its start is lost" {
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
if [[ "$*" == *"/fortio/rest/run"* ]]; then echo 'error: stream closed' >&2; exit 1; fi
STUB
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  grep -Eq '/fortio/rest/stop[?]runid=0$' "$CALLS"
  [ ! -e "$(traffic_directory_of_local)/fortio-run" ]
}

@test "cilium:traffic-start stops no fortio run when it fails before asking for one" {
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--conn-disrupt-test-setup* ]]\n' >"$stubs/cilium"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  ! grep -q '/fortio/rest/stop' "$CALLS"
}

@test "cilium:traffic-check refuses a result file that holds more than one result" {
  started_traffic
  local good
  good=$(fortio_result -c '.')
  printf '%s\n%s\n' "$good" "$(fortio_result -c '.RetCodes = {"-1": 100, "200": 1900}')" >"$FORTIO_RESULT"
  expect_traffic_check_failure "fortio result 2026-09-25-130545_3 is malformed"
  printf '%s\n{}\n' "$good" >"$FORTIO_RESULT"
  rm -f "$CALLS"
  expect_traffic_check_failure "fortio result 2026-09-25-130545_3 is malformed"
}

@test "cilium:traffic-check passes a run at exactly 90% of the requested rate and fails one request below it" {
  local case
  for case in '20000000000 1800 pass' '20000000000 1799 fail' '16970548813 1528 pass' '16970548813 1527 fail'; do
    set -- $case
    rm -f "$CALLS"
    started_traffic
    fortio_result --argjson duration "$1" --argjson count "$2" \
      '.ActualDuration = $duration | .DurationHistogram.Count = $count | .RetCodes = {"200": $count}' >"$FORTIO_RESULT"
    run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
    if [ "$3" = pass ]; then
      [ "$status" -eq 0 ] || fail "$case: $output"
    else
      [ "$status" -ne 0 ] || fail "$case passed"
      [[ "$output" == *"fortio: $2 requests in"*"is under 90% of the 100 a second asked for"* ]] || fail "$case: $output"
    fi
  done
}

@test "cilium:traffic-check gives no verdict when the agent snapshots cannot be compared" {
  started_traffic
  printf '#!/usr/bin/env bash\nexit 2\n' >"$stubs/diff"
  chmod +x "$stubs/diff"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be compared, so there is no verdict"* ]]
  [[ "$output" != *"traffic held"* ]]
  ! grep -q -- '--cleanup' "$CALLS"
}

@test "cilium:traffic-check fails on a fortio result without the fields it measures" {
  started_traffic
  fortio_result 'del(.RetCodes)' >"$FORTIO_RESULT"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"fortio result 2026-09-25-130545_3 is malformed"* ]]
  ! grep -q -- '--cleanup' "$CALLS"
}

# Records each mise call with the branch Flux would follow. FAIL_CALL fails
# the matching call; ON_CALL runs ON_CALL_RUN just before the matching call.
# cilium:traffic-check ends with its verdict, as the real task does.
e2e_mise_stub() {
  cat >"$stubs/mise" <<'STUB'
#!/usr/bin/env bash
printf 'mise %s | branch=%s\n' "$*" "${FIRMAMENT_GIT_BRANCH:-}" >>"$CALLS"
if [[ "$*" == "run cilium:traffic-check"* ]]; then
  printf 'traffic held across the Cilium agent restart\n'
fi
if [[ "$*" == "${ON_CALL:-}" ]]; then
  eval "$ON_CALL_RUN"
fi
[[ "$*" != "${FAIL_CALL:-}" ]]
STUB
  chmod +x "$stubs/mise"
}

# A pushed checkout of feature/test with one environment, as env:e2e needs.
e2e_repository() {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environments/local/environment.yaml "$@")
  export MISE_PROJECT_ROOT
}

# Records each chainsaw call with the KUBECONFIG it runs under.
record_chainsaw_kubeconfig() {
  printf '#!/usr/bin/env bash\nprintf "chainsaw %%s | KUBECONFIG=%%s\\n" "$*" "$KUBECONFIG" >>"$CALLS"\n' >"$stubs/chainsaw"
}

# A pushed checkout of feature/test whose main branch, on origin, already
# hands Cilium to Flux and lists the workloads an upgrade must leave running.
upgrade_repository() {
  e2e_repository packages/cilium/helmrelease.yaml environments/local/tests/upgrade-unaffected
  printf 'kube-system k8s-app=kube-dns\n' >"$MISE_PROJECT_ROOT/environments/local/tests/upgrade-unaffected"
  printf 'TF_VAR_state_directory = "derived"\n' >"$MISE_PROJECT_ROOT/mise.toml"
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

@test "env:e2e reports each step's time before its verdict, and compares the next run with it" {
  e2e_mise_stub
  e2e_repository
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"Step times (change since the last passing run):"* ]]
  [[ "$output" == *"env:destroy "*"(new)"*"env:destroy (2) "*"(new)"* ]]
  [[ "${lines[-1]}" == "env:e2e passed for local at "* ]]
  kept="$FIRMAMENT_STATE_HOME/environments/local/e2e-step-times"
  [ "$(cut -f1 "$kept" | paste -sd, -)" = "env:destroy,env:apply,platform_versions,verify,cilium:conformance,remote_tip_unchanged,env:destroy (2)" ]
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"env:apply "*" s  (+"*" s)"* ]]
}

@test "env:e2e keeps no step times from a failing run" {
  e2e_mise_stub
  e2e_repository
  export FAIL_CALL="run verify"
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [ ! -e "$FIRMAMENT_STATE_HOME/environments/local/e2e-step-times" ]
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
  [ "$output" = "mise run --yes env:destroy
mise run env:apply
mise run verify
mise run cilium:conformance
mise run --yes env:destroy" ]
}

@test "env:e2e stops at the first failing step and leaves the cluster for inspection" {
  e2e_mise_stub
  e2e_repository
  FAIL_CALL="run verify" run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: mise run verify"* ]]
  [[ "$output" == *"Remove it with: mise run --yes env:destroy"* ]]
  [ "$(mise_calls | tail -1)" = "mise run verify" ]
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
  export ON_CALL="run cilium:conformance"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved && git -C "$MISE_PROJECT_ROOT" push -q origin HEAD:refs/heads/feature/test'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/test moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance" ]
}

@test "env:e2e --from-branch applies the baseline branch, verifies it, then applies the checkout over it" {
  e2e_mise_stub
  upgrade_repository
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"Baseline: origin/main at $(git -C "$MISE_PROJECT_ROOT" rev-parse origin/main)"* ]]
  [[ "${lines[-1]}" == "env:e2e passed for local at $(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD): traffic held across the Cilium agent restart; the cluster is destroyed." ]]
  run grep '^mise ' "$CALLS"
  [ "${#lines[@]}" -eq 10 ]
  [ "${lines[0]}" = "mise run --yes env:destroy | branch=feature/test" ]
  [[ "${lines[1]}" == "mise --cd "*"/baseline run env:apply | branch=main" ]]
  [[ "${lines[2]}" == "mise --cd "*"/baseline run env:verify | branch=main" ]]
  [ "${lines[3]}" = "mise run cilium:traffic-start | branch=feature/test" ]
  [ "${lines[4]}" = "mise run env:apply | branch=feature/test" ]
  [ "${lines[5]}" = "mise run verify | branch=feature/test" ]
  [ "${lines[6]}" = "mise run cilium:restart-agent | branch=feature/test" ]
  [ "${lines[7]}" = "mise run cilium:traffic-check | branch=feature/test" ]
  [ "${lines[8]}" = "mise run cilium:conformance | branch=feature/test" ]
  [ "${lines[9]}" = "mise run --yes env:destroy | branch=feature/test" ]
  ! git -C "$MISE_PROJECT_ROOT" worktree list | grep -q /baseline
}

@test "env:e2e --from-branch stops when traffic does not survive the switch, and keeps the cluster" {
  e2e_mise_stub
  upgrade_repository
  FAIL_CALL="run cilium:traffic-check" usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: check_traffic"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:traffic-check" ]
}

@test "env:e2e --from-branch stops when the agent does not restart, before measuring traffic" {
  e2e_mise_stub
  upgrade_repository
  FAIL_CALL="run cilium:restart-agent" usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: mise run cilium:restart-agent"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:restart-agent" ]
}

@test "env:e2e --from-branch stops before the switch when traffic does not start" {
  e2e_mise_stub
  upgrade_repository
  FAIL_CALL="run cilium:traffic-start" usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: mise run cilium:traffic-start"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:traffic-start" ]
}

@test "env:e2e --from-branch fails when the switch replaces a workload it should not touch" {
  e2e_mise_stub
  upgrade_repository
  pods uid-before >"$PODS"
  export ON_CALL="run env:apply"
  export ON_CALL_RUN='pods uid-after >"$PODS"'
  export -f pods
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the upgrade replaced or restarted workloads it should not touch"* ]]
  [[ "$output" == *"uid-before"*"uid-after"* ]]
  [ "$(mise_calls | tail -1)" = "mise run verify" ]
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
  export ON_CALL="run cilium:conformance"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: remote_tip_unchanged feature/test"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance" ]
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
  e2e_repository environments/local/tests/upgrade-unaffected
  commit_and_push "$MISE_PROJECT_ROOT" main k0s-baseline
  git -C "$MISE_PROJECT_ROOT" reset -q --hard origin/feature/test
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main at "*" does not hand Cilium to Flux"* ]]
  [ -z "$(grep '^mise ' "$CALLS" 2>/dev/null)" ]
}

@test "env:e2e --from-branch refuses a baseline that does not derive the state directory from MISE_ENV" {
  e2e_mise_stub
  e2e_repository packages/cilium/helmrelease.yaml environments/local/tests/upgrade-unaffected
  commit_and_push "$MISE_PROJECT_ROOT" main old-state-layout
  git -C "$MISE_PROJECT_ROOT" reset -q --hard origin/feature/test
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main at "*" does not derive the state directory from MISE_ENV"* ]]
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
  export ON_CALL="run cilium:conformance"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" push -q --force origin HEAD:refs/heads/main'
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:conformance" ]
  ! git -C "$MISE_PROJECT_ROOT" worktree list | grep -q /baseline
}

# Runs a task in a pushed copy of this repository's local environment layout,
# on a branch whose only change appends to the given file.
run_changed() {
  local script="$1" changed="$2"
  MISE_PROJECT_ROOT=$(make_pushed_repository main environments/local/environment.yaml \
    clusters/singularity/flux/kustomization.yaml README.md packages/cilium/values.yaml packages/flux/fluxinstance.yaml)
  cp "$root_directory/clusters/singularity/flux/kustomization.yaml" "$MISE_PROJECT_ROOT/clusters/singularity/flux/"
  commit_and_push "$MISE_PROJECT_ROOT" main layout
  git -C "$MISE_PROJECT_ROOT" switch -q -c feature
  printf 'x\n' >>"$MISE_PROJECT_ROOT/$changed"
  export MISE_PROJECT_ROOT
  run_task "$script" local
}

# A pushed checkout whose local environment deploys cilium, which has a
# cluster suite, and flux, which has none.
verify_repository() {
  make_repository clusters/singularity/flux/kustomization.yaml >/dev/null
  printf 'resources:\n  - ../../../packages/cilium\n  - ../../../packages/flux\n' \
    >"$BATS_TEST_TMPDIR/repository/clusters/singularity/flux/kustomization.yaml"
  e2e_repository clusters/singularity/tests/cluster/chainsaw-test.yaml \
    packages/cilium/tests/cluster/chainsaw-test.yaml packages/flux/kustomization.yaml
}

@test "env:verify waits for Flux to apply origin's tip, then checks it" {
  record_chainsaw_kubeconfig
  verify_repository
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -eq 0 ]
  revision="refs/heads/feature/test@sha1:$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)"
  run grep -E '^(kubectl .* wait kustomization|chainsaw )' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait kustomization/flux-system --for=jsonpath={.status.lastAppliedRevision}=$revision --timeout=10m" ]
  [[ "${lines[1]}" =~ ^"chainsaw test --test-dir $MISE_PROJECT_ROOT/clusters/singularity/tests/cluster --test-dir $MISE_PROJECT_ROOT/packages/cilium/tests/cluster --values "([^ ]+)" --set-string flux_revision=$revision | KUBECONFIG=/state/admin.kubeconfig"$ ]]
}

@test "env:verify --only runs the environment's suite and the chosen packages' suites" {
  record_chainsaw_kubeconfig
  verify_repository
  mkdir -p "$MISE_PROJECT_ROOT/packages/flux/tests/cluster"
  : >"$MISE_PROJECT_ROOT/packages/flux/tests/cluster/chainsaw-test.yaml"
  commit_and_push "$MISE_PROJECT_ROOT" feature/test flux-suite
  usage_only=flux run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^chainsaw ' "$CALLS"
  [[ "${lines[0]}" == "chainsaw test --test-dir $MISE_PROJECT_ROOT/clusters/singularity/tests/cluster --test-dir $MISE_PROJECT_ROOT/packages/flux/tests/cluster --values "* ]]
}

@test "env:verify refuses an unknown package before fetching or waiting" {
  verify_repository
  usage_only=nope run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown package 'nope' for environment 'local'; choose from: cilium flux"* ]]
  [ ! -e "$CALLS" ]
}

@test "env:verify gives the suites the runtime values OpenTofu recorded" {
  cat >"$stubs/chainsaw" <<'STUB'
#!/usr/bin/env bash
while (($#)); do
  if [[ "$1" == --values ]]; then cp "$2" "$BATS_TEST_TMPDIR/values"; fi
  shift
done
STUB
  verify_repository
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -eq 0 ]
  [ "$(jq -r .cilium_datapath_mode "$BATS_TEST_TMPDIR/values")" = netkit ]
}

@test "env:verify runs no suite when the state records no runtime values" {
  record_chainsaw_kubeconfig
  verify_repository
  printf 'kubeconfig_path: /state/admin.kubeconfig\n' >"$FIRMAMENT_STATE_HOME/environments/local/cluster-access.yaml"
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' has no .runtime_info in cluster-access.yaml; apply it first"* ]]
  ! grep -q '^chainsaw ' "$CALLS"
}

@test "every value a package suite reads is a runtime value or the Flux revision" {
  local known used
  known=$(grep -Ev '^[[:space:]]*(#|$)' "$root_directory/.mise/flux-test-values.env" | cut -d= -f1)$'\nflux_revision'
  used=$(grep -rhoE '\$values\.[a-z_]+' "$root_directory"/packages/*/tests/cluster | cut -d. -f2 | sort -u)
  [ -n "$used" ]
  while IFS= read -r key; do
    grep -qx -- "$key" <<<"$known" || fail "a package suite reads \$values.$key, which no environment sets"
  done <<<"$used"
}

@test "env:verify runs no suite when it cannot read the environment's Flux build" {
  record_chainsaw_kubeconfig
  verify_repository
  printf 'resources: [\n' >"$MISE_PROJECT_ROOT/clusters/singularity/flux/kustomization.yaml"
  commit_and_push "$MISE_PROJECT_ROOT" feature/test broken
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -ne 0 ]
  ! grep -q '^chainsaw ' "$CALLS"
}

@test "env:verify fails for an environment whose cluster has no suite" {
  MISE_PROJECT_ROOT=$(make_repository environments/bare/environment.yaml clusters/singularity/flux/kustomization.yaml)
  run_task "$root_directory/.mise/tasks/env/verify.sh" bare
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'bare' runs a cluster with no suite at $MISE_PROJECT_ROOT/clusters/singularity/tests/cluster"* ]]
  [ ! -e "$CALLS" ]
}

# Builds a stand-in repository with one chainsaw suite for cluster "x":
# the singularity suite, edited by the given yq expression. Uses the real
# chainsaw.
edited_suite_repository() {
  local repository suite=clusters/x/tests/cluster/chainsaw-test.yaml
  repository=$(make_repository "$suite")
  yq "$1" "$root_directory/clusters/singularity/tests/cluster/chainsaw-test.yaml" >"$repository/$suite"
  rm "$stubs/chainsaw"
  printf '%s\n' "$repository"
}

@test "chainsaw:lint rejects a package suite that changes the cluster" {
  local repository suite=packages/x/tests/cluster/chainsaw-test.yaml
  repository=$(make_repository "$suite")
  yq '.spec.steps[0].try[0] = {"apply": .spec.steps[0].try[0].assert}' \
    "$root_directory/packages/cilium/tests/cluster/chainsaw-test.yaml" >"$repository/$suite"
  rm "$stubs/chainsaw"
  MISE_PROJECT_ROOT=$repository run "$root_directory/.mise/tasks/chainsaw/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$suite: try may not run apply"* ]]
}

@test "chainsaw:lint accepts every environment's and package's cluster suite" {
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
  MISE_PROJECT_ROOT=$(make_repository environments/local/environment.yaml)
  run "$MISE_PROJECT_ROOT/.mise/tasks/flux/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no clusters/*/flux build to validate"* ]]
}

@test "flux:lint validates without the network, against the vendored schemas" {
  rm "$stubs/kubectl"
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 run "$root_directory/.mise/tasks/flux/lint.sh"
  [ "$status" -eq 0 ]
}

@test "flux:lint names flux:schemas when a kind has no vendored schema" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/clusters/new/flux"
  cat >"$MISE_PROJECT_ROOT/clusters/new/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/clusters/new/flux/secret.yaml" <<'YAML'
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
  cp -R "$root_directory/clusters" "$root_directory/packages" "$repository/"
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
  cp -R "$root_directory/clusters" "$root_directory/packages" "$repository/"
  MISE_PROJECT_ROOT="$repository" run "$repository/.mise/tasks/flux/schemas.sh"
  [ "$status" -ne 0 ]
  diff -r "$root_directory/.mise/flux-schemas" "$repository/.mise/flux-schemas"
}

@test "flux:lint rejects a Flux build that breaks its schema" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/clusters/bad/flux"
  cat >"$MISE_PROJECT_ROOT/clusters/bad/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/clusters/bad/flux/helmrelease.yaml" <<'YAML'
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
  [[ "$output" == *"clusters/bad/flux: the rendered Flux build is not valid"* ]]
}

@test "flux:lint rejects a Flux build with a variable no runtime value sets" {
  rm "$stubs/kubectl"
  MISE_PROJECT_ROOT=$(make_repository)
  mkdir -p "$MISE_PROJECT_ROOT/clusters/bad/flux"
  cat >"$MISE_PROJECT_ROOT/clusters/bad/flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
YAML
  cat >"$MISE_PROJECT_ROOT/clusters/bad/flux/configmap.yaml" <<'YAML'
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

@test "orb:capture-stall kills a command that ignores the timeout's TERM" {
  printf '#!/usr/bin/env bash\ntrap "" TERM\nexec sleep 300\n' >"$stubs/arp"
  chmod +x "$stubs/arp"
  FIRMAMENT_CAPTURE_SECONDS=1 run_capture_stall
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(tail -1 "$FIRMAMENT_STATE_HOME"/stalls/*/host-arp.txt)" = 'exit 137' ]
  grep -q '^orb -m demo -u root journalctl ' "$CALLS"
}

@test "orb:capture-stall captures in-machine state when run from a terminal" {
  local tool
  for tool in arp dscacheutil route lsof; do
    [ -e "$stubs/$tool" ] || stub "$tool"
  done
  # orb sets terminal modes; a process in a background process group that
  # does so is stopped until its capture times out.
  cat >"$stubs/orb" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-m "*) stty sane </dev/tty && printf 'captured\n' ;;
esac
STUB
  chmod +x "$stubs/orb"
  run script -q /dev/null env usage_machine=demo FIRMAMENT_CAPTURE_SECONDS=2 \
    "$root_directory/.mise/tasks/orb/capture-stall.sh" </dev/null
  local directory
  directory=$(printf '%s\n' "$FIRMAMENT_STATE_HOME"/stalls/*)
  [ "$(tail -1 "$directory/machine-sockets.txt")" = 'exit 0' ] || fail "$(cat "$directory/machine-sockets.txt")"
  grep -qx captured "$directory/machine-ssh-journal.txt"
}

@test "orb:capture-stall never uploads an orb report no one can review" {
  run_capture_stall
  [ "$status" -eq 0 ] || fail "$output"
  ! grep -q '^orb report' "$CALLS"
  [[ "$output" == *"Skipped orb report: no terminal to review it."* ]]
}

# Runs env:doctor for the local environment, which has an applied state
# unless a test removes it.
# Runs env:doctor for the local environment. Unless a test says otherwise,
# the state records the machine and the cluster, and the kubeconfig file
# exists.
# Runs env:doctor against the recorded machine and cluster, with a
# kubeconfig file that exists unless DOCTOR_KUBECONFIG names another path.
# A test removes a contract first to record less.
run_doctor() {
  local contract="$FIRMAMENT_STATE_HOME/environments/local/cluster-access.yaml"
  local kubeconfig="$BATS_TEST_TMPDIR/admin.kubeconfig"
  : >"$kubeconfig"
  if [[ -f "$contract" ]]; then
    yq -i ".kubeconfig_path = \"${DOCTOR_KUBECONFIG:-$kubeconfig}\"" "$contract"
  fi
  run_task "$root_directory/.mise/tasks/env/doctor.sh" local
}

@test "env:doctor passes on a healthy host and changes nothing" {
  local_state
  run_doctor
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"ok    orbstack: running"* ]]
  [[ "$output" == *"ok    machine: firmament is running"* ]]
  [[ "$output" == *"ok    api: the API server is ready"* ]]
  [[ "$output" != *FAIL* ]]
  ! grep -Eq '^tofu .* (init|apply|destroy|state (mv|rm))( |$)' "$CALLS" || fail "changed state: $(cat "$CALLS")"
  [ ! -e "$FIRMAMENT_STATE_HOME/environments/local/owner" ] || fail "claimed the environment"
}

@test "env:doctor treats an environment with no state as ready for env:apply" {
  forget_contract machine-hosts.yaml
  forget_contract cluster-access.yaml
  run_doctor
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"skip  machine: no machine recorded yet; env:apply creates it"* ]]
  ! grep -q '^orb ' "$CALLS"
}

@test "env:doctor names the worktree that owns the environment" {
  local_state
  local other="$BATS_TEST_TMPDIR/other-worktree"
  mkdir -p "$other"
  printf '%s\n' "$other" >"$FIRMAMENT_STATE_HOME/environments/local/owner"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  owner: the worktree $other owns this environment"* ]]
  [[ "$output" == *"next: run the task there, or set FIRMAMENT_TAKE_OVER=1"* ]]
}

@test "env:doctor reports an empty state file with the backup to restore" {
  mkdir -p "$FIRMAMENT_STATE_HOME/environments/local"
  : >"$FIRMAMENT_STATE_HOME/environments/local/machine-orb.tfstate"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  state: "*"machine-orb.tfstate is empty"* ]]
}

@test "env:doctor reports a contract file it cannot read, and what writes it again" {
  local_state
  printf 'name: [unclosed\n' >"$FIRMAMENT_STATE_HOME/environments/local/machine-hosts.yaml"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  state: cannot read $FIRMAMENT_STATE_HOME/environments/local/machine-hosts.yaml"* ]]
  [[ "$output" == *"next: mise run orb:apply, which writes it again"* ]]
}

@test "env:doctor stops at a stopped OrbStack and skips what depends on it" {
  local_state
  ORBCTL_STATUS=Stopped run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  orbstack: OrbStack is Stopped"* ]]
  [[ "$output" == *"next: orbctl start"* ]]
  [[ "$output" == *"skip  machine: OrbStack is not running"* ]]
  ! grep -q '^orb ' "$CALLS"
}

@test "env:doctor tells how to start a stopped machine" {
  local_state
  ORB_STATE=stopped run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  machine: firmament is stopped"* ]]
  [[ "$output" == *"next: orb start firmament"* ]]
  [[ "$output" == *"skip  api: the machine is not running"* ]]
}

@test "env:doctor reports a name the Mac cannot resolve" {
  local_state
  HOST_DNS_ERROR=1 run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  host dns: the Mac cannot resolve firmament.orb.local"* ]]
}

@test "env:doctor reports names the machine cannot resolve" {
  local_state
  ORB_DNS_ERROR=1 run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  machine dns: firmament cannot resolve host.orb.internal"* ]]
  [[ "$output" == *"FAIL  machine dns: firmament cannot resolve ghcr.io"* ]]
}

@test "env:doctor explains no route to the API server as missing Local Network access" {
  local_state
  READYZ_ERROR='dial tcp 192.168.139.53:6443: connect: no route to host' run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: no route to the API server"* ]]
  [[ "$output" == *"Local Network"* ]]
}

@test "env:doctor reports an API server that is not ready" {
  local_state
  READYZ_ERROR='the server is currently unable to handle the request' run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: the server is currently unable to handle the request"* ]]
  [[ "$output" == *"next: mise run k0s:verify"* ]]
}

@test "env:doctor tells a dead .orb.local name from a dead machine" {
  local_state
  READYZ_ERROR='dial tcp 192.168.138.4:6443: connect: operation timed out' IP_READYZ_OK=1 run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: the machine answers at 192.168.139.101 but its .orb.local name does not: dial tcp 192.168.138.4:6443: connect: operation timed out"* ]]
  [[ "$output" == *"next: orb restart firmament"* ]]
  grep -q -- '--server https://192.168.139.101:6443 --tls-server-name firmament.orb.local' "$CALLS"
}

@test "env:doctor probes the machine from a terminal without stopping orb" {
  local_state
  # orb sets terminal modes; a process in a background process group that
  # does so is stopped until the probe times out.
  cat >"$stubs/orb" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "info "*) printf '{"record":{"name":"firmament","state":"running"}}' ;;
  *" getent hosts "*) stty sane </dev/tty && printf 'fd07::fe  %s\n' "${*: -1}" ;;
esac
STUB
  chmod +x "$stubs/orb"
  record_contracts "$BATS_TEST_TMPDIR/admin.kubeconfig"
  : >"$BATS_TEST_TMPDIR/admin.kubeconfig"
  run script -q /dev/null env TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" \
    "$root_directory/.mise/tasks/env/doctor.sh" </dev/null
  output=${output//$'\r'/}
  [[ "$output" == *"ok    machine dns: firmament resolves host.orb.internal"* ]] || fail "$output"
  [[ "$output" == *"ok    machine dns: firmament resolves ghcr.io"* ]] || fail "$output"
}

@test "env:doctor treats a missing machine-hosts contract as no machine" {
  local_state
  forget_contract machine-hosts.yaml
  run_doctor
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"skip  machine: no machine recorded yet; env:apply creates it"* ]]
  ! grep -q '^orb ' "$CALLS"
}

@test "env:doctor skips the API server while no cluster is recorded" {
  local_state
  forget_contract cluster-access.yaml
  run_doctor
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"skip  api: no cluster recorded yet; env:apply creates it"* ]]
  ! grep -q 'readyz' "$CALLS"
}

@test "env:doctor sends a missing kubeconfig file to k0s:apply, which writes it again" {
  local_state
  DOCTOR_KUBECONFIG="$BATS_TEST_TMPDIR/missing.kubeconfig" run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: the kubeconfig file $BATS_TEST_TMPDIR/missing.kubeconfig is missing"* ]]
  [[ "$output" == *"next: mise run k0s:apply"* ]]
  ! grep -q 'readyz' "$CALLS"
}

@test "repo:setup creates the shared OpenTofu provider cache" {
  stub hk
  export TF_PLUGIN_CACHE_DIR="$BATS_TEST_TMPDIR/cache/tofu-plugins"
  run "$root_directory/.mise/tasks/repo/setup.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ -d "$TF_PLUGIN_CACHE_DIR" ] || fail "no cache directory at $TF_PLUGIN_CACHE_DIR"
  grep -q '^hk install --mise ' "$CALLS" || fail "hk hooks not installed: $(cat "$CALLS")"
}

# A stand-in repository holding a copy of the layout contract.
contract_repository() {
  local repository
  repository=$(make_repository)
  cp -R "$root_directory/contracts" "$repository/"
  printf '%s\n' "$repository"
}

@test "contracts:lint accepts every contract in the repository" {
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "contracts:lint refuses a field the schema does not declare, naming the file and field" {
  MISE_PROJECT_ROOT=$(contract_repository)
  yq -i '.folders.roots.owner = "someone"' "$MISE_PROJECT_ROOT/contracts/layout/layout.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"folders.roots.owner"* ]] || fail "$output"
  [[ "$output" == *"contracts/layout: data does not match #Contract"* ]]
}

@test "contracts:lint refuses a layout that leaves out a folder" {
  MISE_PROJECT_ROOT=$(contract_repository)
  yq -i 'del(.folders.clusters)' "$MISE_PROJECT_ROOT/contracts/layout/layout.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"folders.clusters"* ]] || fail "$output"
}

@test "contracts:lint fails when there is no contract to check" {
  MISE_PROJECT_ROOT=$(make_repository)
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no contracts/*/schema.cue to check"* ]]
}

@test "secrets:lint fails on a private key in a tracked file without an extension" {
  local repository="$BATS_TEST_TMPDIR/leaky"
  mkdir -p "$repository/keys"
  cp "$root_directory/hk.pkl" "$repository/"
  git -C "$repository" init -q
  ssh-keygen -q -t ed25519 -N '' -C test -f "$repository/keys/id_ed25519" >/dev/null
  git -C "$repository" add hk.pkl keys/id_ed25519
  run bash -c "cd '$repository' && hk check --all --step betterleaks"
  [ "$status" -ne 0 ] || fail "accepted a private key: $output"
  [[ "$output" == *"keys/id_ed25519"* ]] || fail "$output"
}

# A repository whose task scripts are real files, one environment named local.
environment_lint_repository() {
  local repository="$BATS_TEST_TMPDIR/lint-repository"
  mkdir -p "$repository/environments/local" "$repository/.mise/tasks/x"
  printf '%s\n' "$repository"
}

@test "environments:lint accepts every task script in the repository" {
  run "$root_directory/.mise/tasks/environments/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "environments:lint refuses an environment named as a string, a path or an assignment" {
  MISE_PROJECT_ROOT=$(environment_lint_repository)
  local line
  for line in 'environment="local"' "x='local'" 'dir=$root/environments/local/tests' 'MISE_ENV=local mise run y'; do
    printf '%s\n' "$line" >"$MISE_PROJECT_ROOT/.mise/tasks/x/bad.sh"
    run "$root_directory/.mise/tasks/environments/lint.sh"
    [ "$status" -ne 0 ] || fail "accepted: $line"
    [[ "$output" == *".mise/tasks/x/bad.sh: names environment local"* ]] || fail "$output"
    [[ "$output" == *"1:$line"* ]] || fail "$output"
  done
}

@test "environments:lint ignores comments, the local keyword and longer names" {
  MISE_PROJECT_ROOT=$(environment_lint_repository)
  printf '%s\n' '# the local environment is "local"' 'f() { local x=1; }' 'cluster="local-cluster"' 'path=environments/localhost/x' \
    >"$MISE_PROJECT_ROOT/.mise/tasks/x/ok.sh"
  run "$root_directory/.mise/tasks/environments/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
}
