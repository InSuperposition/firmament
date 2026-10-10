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
# The UI tasks forward to a random high port, so a
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
    "$root_directory/.mise/tasks/env/e2e.sh" "$root_directory"/.mise/tasks/cilium/{restart-agent,traffic-start,traffic-check}.sh; do
    grep -qx 'claim_environment' "$script" || fail "$script changes the environment without claiming it"
  done
}

@test "env:apply refuses an environment another worktree owns, before applying" {
  e2e_repository
  mkdir -p "$BATS_TEST_TMPDIR/other-worktree" "$FIRMAMENT_STATE_HOME/environments/local"
  printf '%s\n' "$BATS_TEST_TMPDIR/other-worktree" >"$FIRMAMENT_STATE_HOME/environments/local/owner"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to the worktree $BATS_TEST_TMPDIR/other-worktree"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

# Removes one contract file of the local environment but leaves the
# kubeconfig, as a failed apply does when it withdraws cluster-access.yaml
# while the cluster is still there.
forget_contract_only() {
  rm -f "$FIRMAMENT_STATE_HOME/environments/local/$1"
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
  ! grep -q ' state rm ' "$CALLS" || fail "removed state with no allocation records: $(cat "$CALLS")"
}

@test "env:destroy forgets the allocation records before destroying the Kubernetes root, and only those" {
  local_state
  TOFU_STATE_LIST=$'terraform_data.allocation["singularity"]\nterraform_data.environment_contract\nlocal_file.k0sctl' \
    run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  run grep -E '^tofu -chdir=.* (state rm|destroy) ' "$CALLS"
  [ "${#lines[@]}" -eq 3 ] || fail "${lines[*]}"
  [[ "${lines[0]}" == "tofu -chdir=$root_directory/roots/kubernetes-k0s state rm terraform_data.allocation[\"singularity\"] "* ]]
  [[ "${lines[1]}" == "tofu -chdir=$root_directory/roots/kubernetes-k0s destroy -input=false -auto-approve "* ]]
  [[ "${lines[2]}" == "tofu -chdir=$root_directory/roots/machine-orb destroy -input=false -auto-approve "* ]]
}

@test "env:destroy removes what the k0sctl edge wrote, even with no state file, and runs twice" {
  local state="$FIRMAMENT_STATE_HOME/environments/local"
  printf 'x\n' >"$state/known_hosts"
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [ ! -e "$state/admin.kubeconfig" ] && [ ! -e "$state/k0sctl.yaml" ] && [ ! -e "$state/known_hosts" ]
  run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ] || fail "$output"
}

@test "orb:destroy forgets the allocation records and removes the edge's files too" {
  local state="$FIRMAMENT_STATE_HOME/environments/local"
  local_state
  TOFU_STATE_LIST='terraform_data.allocation["singularity"]' run_task "$root_directory/.mise/tasks/orb/destroy.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  grep -q ' state rm terraform_data.allocation\["singularity"\] ' "$CALLS"
  [ ! -e "$state/admin.kubeconfig" ] && [ ! -e "$state/k0sctl.yaml" ]
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

@test "env:apply applies the machine root, the Kubernetes root around the k0sctl edge, then the bootstrap root, then waits" {
  e2e_repository
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  local state="$FIRMAMENT_STATE_HOME/environments/local" k0s="$MISE_PROJECT_ROOT/roots/kubernetes-k0s"
  run grep -E '^(tofu -chdir=.* (init|apply) |k0sctl |kubectl .*--raw /readyz|cilium |mise run openbao:)' "$CALLS"
  [[ "${lines[0]}" == "tofu -chdir=$MISE_PROJECT_ROOT/roots/machine-orb init "*"-backend-config=path=$state/machine-orb.tfstate "* ]]
  [[ "${lines[1]}" == "tofu -chdir=$MISE_PROJECT_ROOT/roots/machine-orb apply -input=false -auto-approve "* ]]
  [[ "${lines[2]}" == "tofu -chdir=$k0s init "*"-backend-config=path=$state/kubernetes-k0s.tfstate "* ]]
  [[ "${lines[3]}" == "tofu -chdir=$k0s apply -input=false -auto-approve -var=publish_cluster_access=false "* ]]
  [[ "${lines[4]}" == "k0sctl apply --config $state/k0sctl.yaml --no-drain --timeout 900s "* ]]
  [[ "${lines[5]}" == "k0sctl kubeconfig --config $state/k0sctl.yaml "* ]]
  [[ "${lines[6]}" == "kubectl --kubeconfig $state/admin.kubeconfig get --raw /readyz "* ]]
  [[ "${lines[7]}" == "tofu -chdir=$k0s apply -input=false -auto-approve -var=publish_cluster_access=true "* ]]
  [[ "${lines[8]}" == "tofu -chdir=$MISE_PROJECT_ROOT/roots/bootstrap-flux init "*"-backend-config=path=$state/bootstrap-flux.tfstate "* ]]
  [[ "${lines[9]}" == "tofu -chdir=$MISE_PROJECT_ROOT/roots/bootstrap-flux apply -input=false -auto-approve "* ]]
  [[ "${lines[10]}" == "cilium --kubeconfig /state/admin.kubeconfig status"* ]]
  [[ "${lines[11]}" == "cilium --kubeconfig /state/admin.kubeconfig status"* ]]
  [[ "${lines[12]}" == "mise run openbao:seed"* ]]
  [[ "${lines[13]}" == "mise run openbao:restore"* ]]
  [[ "${lines[14]}" == "mise run openbao:root"* ]]
  [[ "${lines[15]}" == "mise run openbao:snapshot"* ]]
}

@test "env:plan plans every root once the environment records a machine and a cluster" {
  e2e_repository
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  local root
  for root in machine-orb kubernetes-k0s bootstrap-flux; do
    grep -q "^tofu -chdir=$MISE_PROJECT_ROOT/roots/$root plan -input=false " "$CALLS" || fail "$root not planned"
  done
}

@test "env:plan skips the bootstrap root while the environment records no cluster" {
  e2e_repository
  forget_contract cluster-access.yaml
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"No cluster recorded yet, so the bootstrap is not planned"* ]]
  grep -q "^tofu -chdir=$MISE_PROJECT_ROOT/roots/kubernetes-k0s plan -input=false " "$CALLS"
  ! grep -q -- 'roots/bootstrap-flux' "$CALLS" || fail "ran tofu in the bootstrap root: $(cat "$CALLS")"
}

@test "env:plan plans only the machine root while the environment records no machine" {
  e2e_repository
  forget_contract machine-hosts.yaml
  forget_contract cluster-access.yaml
  run_task "$root_directory/.mise/tasks/env/plan.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"No machine recorded yet, so k0s and the bootstrap are not planned"* ]]
  grep -q "^tofu -chdir=$MISE_PROJECT_ROOT/roots/machine-orb plan -input=false " "$CALLS"
  ! grep -qE -- 'roots/(kubernetes-k0s|bootstrap-flux)' "$CALLS" || fail "planned a later root: $(cat "$CALLS")"
}

@test "env:apply refuses a recorded cluster that cannot say whether k0s installs charts" {
  e2e_repository
  K0S_CHARTS_ERROR="Unable to connect to the server: dial tcp: i/o timeout" run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell whether k0s installs Helm charts"*"i/o timeout"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply refuses a contract file it cannot read" {
  e2e_repository
  printf 'name: [unclosed\n' >"$FIRMAMENT_STATE_HOME/environments/local/machine-hosts.yaml"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply applies a destroyed environment without asking it for k0s charts" {
  e2e_repository
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
  e2e_repository
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ]
  grep -q 'get charts.helm.k0sproject.io' "$CALLS"
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
}

# Records the commit each tofu call is told Flux follows.
record_pinned_commit() {
  own_stub tofu
  printf '#!/usr/bin/env bash\nprintf "tofu %%s | commit=%%s\\n" "$*" "${TF_VAR_git_commit:-}" >>"$CALLS"\n' >"$stubs/tofu"
}

@test "env:apply pins Flux to the tip of the branch on origin in every pass of the Kubernetes root" {
  e2e_repository
  record_pinned_commit
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  local tip
  tip=$(git -C "$MISE_PROJECT_ROOT" rev-parse origin/feature/test)
  run grep -E "^tofu -chdir=.*/kubernetes-k0s apply " "$CALLS"
  [ "${#lines[@]}" -eq 2 ] || fail "${lines[*]}"
  [[ "${lines[0]}" == *"| commit=$tip" ]] || fail "${lines[0]}"
  [[ "${lines[1]}" == *"| commit=$tip" ]] || fail "${lines[1]}"
}

@test "env:apply refuses a checkout that is not the pushed tip, before any tool runs" {
  e2e_repository
  git -C "$MISE_PROJECT_ROOT" -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m unpushed
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not origin/feature/test"*"push or pull first"* ]] || fail "$output"
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply refuses uncommitted changes, which Flux cannot see" {
  e2e_repository
  : >"$MISE_PROJECT_ROOT/untracked-file"
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the working tree has changes Flux cannot see"* ]] || fail "$output"
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "env:apply asks no cluster for charts while the machine-hosts contract is missing" {
  e2e_repository
  forget_contract machine-hosts.yaml
  run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  ! grep -q 'get charts.helm.k0sproject.io' "$CALLS" || fail "asked a destroyed cluster for charts"
  grep -q ' apply -input=false -auto-approve ' "$CALLS"
}

@test "env:apply refuses a cluster whose Helm charts k0s still installs" {
  e2e_repository
  K0S_CHARTS=chart.helm.k0sproject.io/k0s-addon-chart-cilium run_task "$root_directory/.mise/tasks/env/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0s still installs Helm charts on this cluster"*"k0s-addon-chart-cilium"* ]]
  ! grep -q ' apply -input=false' "$CALLS"
}

@test "k0s:apply renders, runs k0sctl, publishes the contract, then waits for the node" {
  e2e_repository
  NODES=node/firmament run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  run grep -nE '^(tofu .* apply |k0sctl |kubectl |cilium )' "$CALLS"
  [ "${#lines[@]}" -eq 7 ] || fail "${lines[*]}"
  [[ "${lines[0]}" == *"get charts.helm.k0sproject.io "* ]]
  [[ "${lines[1]}" == *"tofu -chdir=$MISE_PROJECT_ROOT/roots/kubernetes-k0s apply -input=false -auto-approve -var=publish_cluster_access=false "* ]]
  [[ "${lines[2]}" == *"k0sctl apply --config "* ]]
  [[ "${lines[3]}" == *"k0sctl kubeconfig --config "* ]]
  [[ "${lines[4]}" == *"get --raw /readyz "* ]]
  [[ "${lines[5]}" == *"tofu -chdir=$MISE_PROJECT_ROOT/roots/kubernetes-k0s apply -input=false -auto-approve -var=publish_cluster_access=true "* ]]
  [[ "${lines[6]}" == *"get nodes -o name "* ]]
}

@test "k0s:apply refuses a cluster whose Helm charts k0s still installs, before k0sctl runs" {
  e2e_repository
  K0S_CHARTS=chart.helm.k0sproject.io/k0s-addon-chart-cilium run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0s still installs Helm charts on this cluster"* ]]
  ! grep -qE '^(k0sctl|tofu .* apply) ' "$CALLS" || fail "$(cat "$CALLS")"
}

@test "the k0sctl edge still asks for charts after a failed run withdrew the cluster-access contract" {
  forget_contract_only cluster-access.yaml
  K0S_CHARTS=chart.helm.k0sproject.io/k0s-addon-chart-cilium run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0s still installs Helm charts on this cluster"* ]]
  ! grep -q '^k0sctl ' "$CALLS"
}

@test "k0s:apply stops at a failed k0sctl apply and never publishes the contract" {
  e2e_repository
  K0SCTL_APPLY_ERROR="connect: connection refused" run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"connection refused"* ]]
  [[ "$output" == *"k0sctl apply failed or ran over 900s; the cluster-access contract stays withdrawn, and rerunning is safe"* ]]
  ! grep -q 'k0sctl kubeconfig' "$CALLS"
  ! grep -q 'publish_cluster_access=true' "$CALLS" || fail "published after a failed apply"
}

@test "k0s:apply kills a k0sctl apply that runs over FIRMAMENT_K0SCTL_SECONDS and never publishes" {
  e2e_repository
  K0SCTL_APPLY_SLEEP=60 FIRMAMENT_K0SCTL_SECONDS=1 run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"ran over 1s"* ]]
  grep -q -- '--timeout 1s ' "$CALLS"
  ! grep -q 'publish_cluster_access=true' "$CALLS"
}

@test "k0s:apply refuses a FIRMAMENT_K0SCTL_SECONDS that is not a whole number of seconds, before k0sctl runs" {
  e2e_repository
  FIRMAMENT_K0SCTL_SECONDS=soon run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"FIRMAMENT_K0SCTL_SECONDS must be a whole number of seconds"* ]]
  ! grep -q '^k0sctl ' "$CALLS"
}

@test "k0s:apply keeps the old kubeconfig, leaves no temp file and never publishes when k0sctl kubeconfig fails" {
  e2e_repository
  local state="$FIRMAMENT_STATE_HOME/environments/local"
  printf 'old\n' >"$state/admin.kubeconfig"
  K0SCTL_KUBECONFIG_ERROR="no such host" run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"k0sctl kubeconfig failed; the cluster-access contract stays withdrawn, and rerunning is safe"* ]]
  [ "$(cat "$state/admin.kubeconfig")" = old ]
  [ -z "$(find "$state" -name '.admin.kubeconfig.*')" ]
  ! grep -q 'publish_cluster_access=true' "$CALLS"
}

@test "k0s:apply never publishes while the API does not answer /readyz at the kubeconfig's address" {
  e2e_repository
  READYZ_ERROR="connection refused" FIRMAMENT_API_SECONDS=1 run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the API server did not answer /readyz within 1s"* ]]
  ! grep -q 'publish_cluster_access=true' "$CALLS"
}

@test "k0s:apply writes a whole kubeconfig readable by its owner only, and a second run ends the same" {
  e2e_repository
  local state="$FIRMAMENT_STATE_HOME/environments/local" first
  rm -f "$state/admin.kubeconfig"
  NODES=node/firmament run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(stat -f %Lp "$state/admin.kubeconfig" 2>/dev/null || stat -c %a "$state/admin.kubeconfig")" = 600 ]
  first=$(cat "$state/admin.kubeconfig")
  [[ "$first" == *"kind: Config"*"clusters: []"* ]]
  NODES=node/firmament run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$state/admin.kubeconfig")" = "$first" ]
  [ -z "$(find "$state" -name '.admin.kubeconfig.*')" ]
  [ "$(grep -c '^k0sctl apply ' "$CALLS")" -eq 2 ]
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
  [[ "${lines[1]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system get configmap cilium-values-policy "* ]]
  [[ "${lines[2]}" == "helm --kubeconfig /state/admin.kubeconfig -n kube-system get values cilium -o yaml "* ]]
  [[ "${lines[3]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system rollout status daemonset/cilium --timeout=10m "* ]]
  [[ "${lines[4]}" == "cilium --kubeconfig /state/admin.kubeconfig status --wait --interactive=false "* ]]
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
  own_stub tofu
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
  own_stub kubectl
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
  [ "${#lines[@]}" -eq 10 ]
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete ciliumclusterwidenetworkpolicies.cilium.io -l firmament.test/traffic-fixtures --ignore-not-found "* ]]
  [[ "${lines[1]}" == "kubectl --kubeconfig /state/admin.kubeconfig apply -f $MISE_PROJECT_ROOT/.mise/traffic/permit.yaml "* ]]
  [[ "${lines[2]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete namespace traffic-probe --ignore-not-found --timeout=2m "* ]]
  [[ "${lines[3]}" == "kubectl --kubeconfig /state/admin.kubeconfig apply -f $MISE_PROJECT_ROOT/.mise/traffic/fortio.yaml "* ]]
  [[ "${lines[4]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe rollout status deployment/fortio-server deployment/fortio-client --timeout=3m "* ]]
  [[ "${lines[5]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --conn-disrupt-test-setup --include-conn-disrupt-test --conn-disrupt-client-timeout 1s --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[6]}" == "kubectl --kubeconfig /state/admin.kubeconfig get namespace cilium-test-1 "* ]]
  [[ "${lines[7]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n traffic-probe exec deployment/fortio-client -- fortio curl -quiet -timeout 30s -payload "*" http://localhost:8080/fortio/rest/run "* ]]
  [[ "${lines[8]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/status?runid=3 "* ]]
  [[ "${lines[9]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  local payload
  payload=$(sed -n 's/.* -payload \({.*}\) http:.*/\1/p' <<<"${lines[7]}")
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
  own_stub kubectl
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
  own_stub cilium
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
  [ "${#lines[@]}" -eq 9 ]
  [[ "${lines[0]}" == "kubectl --kubeconfig /state/admin.kubeconfig get ciliumclusterwidenetworkpolicies.cilium.io traffic-fixtures-permit "* ]]
  [[ "${lines[1]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/status?runid=3 "* ]]
  [[ "${lines[2]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --include-conn-disrupt-test --conn-disrupt-test-restarts-path $traffic/conn-disrupt-restarts --test no-interrupted-connections "* ]]
  [[ "${lines[3]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/rest/stop?runid=3&wait=on "* ]]
  [[ "${lines[4]}" == "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get pods -l k8s-app=cilium -o json "* ]]
  [[ "${lines[5]}" == *" fortio curl -quiet -timeout 30s http://localhost:8080/fortio/data/2026-09-25-130545_3.json "* ]]
  [[ "${lines[6]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete namespace traffic-probe --timeout=2m "* ]]
  [[ "${lines[7]}" == "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup "* ]]
  [[ "${lines[8]}" == "kubectl --kubeconfig /state/admin.kubeconfig delete ciliumclusterwidenetworkpolicies.cilium.io -l firmament.test/traffic-fixtures --ignore-not-found "* ]]
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
  own_stub cilium
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
  own_stub cilium
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
  own_stub kubectl
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
  own_stub cilium
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--include-conn-disrupt-test* ]]\n' >"$stubs/cilium"
  export FORTIO_STOP="$BATS_TEST_TMPDIR/stop.json"
  printf '{"message":"stopping","ResultID":""}\n' >"$FORTIO_STOP"
  expect_traffic_check_failure "conn-disrupt: a connection held open since cilium:traffic-start broke" "fortio did not stop run 3 with a saved result"
}

@test "cilium:traffic-check fails and keeps the workloads when fortio does not return the result" {
  started_traffic
  own_stub kubectl
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
  own_stub kubectl
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
  own_stub kubectl
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
  own_stub cilium
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
  own_stub mise
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
  own_stub chainsaw
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
  [ "$(cut -f1 "$kept" | paste -sd, -)" = "env:destroy,env:apply,platform_versions,verify,network-policy:verify,remote_tip_unchanged,env:destroy (2)" ]
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
mise run network-policy:verify
mise run --yes env:destroy" ]
}

@test "env:e2e --rebuild-check destroys and applies again after verify, then compares OpenBao's root and verifies again" {
  e2e_mise_stub
  e2e_repository clusters/singularity/packages.yaml
  printf -- '- package: openbao\n  namespace: openbao\n  tenant: platform\n' >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  commit_and_push "$MISE_PROJECT_ROOT" feature/test packages
  record_contracts
  own_stub kubectl
  printf '#!/usr/bin/env bash\n[[ "$*" == *" exec "* ]] && printf "ROOT:A\\n"\nexit 0\n' >"$stubs/kubectl"
  chmod +x "$stubs/kubectl"
  usage_rebuild_check=true run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  run mise_calls
  [ "$output" = "mise run --yes env:destroy
mise run env:apply
mise run verify
mise run network-policy:verify
mise run --yes env:destroy
mise run env:apply
mise run verify
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
  export ON_CALL="run network-policy:verify"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved && git -C "$MISE_PROJECT_ROOT" push -q origin HEAD:refs/heads/feature/test'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/test moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run network-policy:verify" ]
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
  [ "${lines[6]}" = "mise run network-policy:verify | branch=feature/test" ]
  [ "${lines[7]}" = "mise run cilium:restart-agent | branch=feature/test" ]
  [ "${lines[8]}" = "mise run cilium:traffic-check | branch=feature/test" ]
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
  [ "$(mise_calls | tail -1)" = "mise run network-policy:verify" ]
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
  export ON_CALL="run network-policy:verify"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"'
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: remote_tip_unchanged feature/test"* ]]
  [ "$(mise_calls | tail -1)" = "mise run network-policy:verify" ]
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
  export ON_CALL="run cilium:traffic-check"
  export ON_CALL_RUN='git -C "$MISE_PROJECT_ROOT" push -q --force origin HEAD:refs/heads/main'
  usage_from_branch=main run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main moved from"*"during the run"* ]]
  [ "$(mise_calls | tail -1)" = "mise run cilium:traffic-check" ]
  ! git -C "$MISE_PROJECT_ROOT" worktree list | grep -q /baseline
}

# Runs a task in a pushed copy of this repository's local environment layout,
# on a branch whose only change appends to the given file.
run_changed() {
  local script="$1" changed="$2"
  MISE_PROJECT_ROOT=$(make_pushed_repository main environments/local/environment.yaml \
    clusters/singularity/payload/kustomization.yaml README.md packages/cilium/values.yaml packages/flux/fluxinstance.yaml)
  cp "$root_directory/clusters/singularity/payload/kustomization.yaml" "$MISE_PROJECT_ROOT/clusters/singularity/payload/"
  commit_and_push "$MISE_PROJECT_ROOT" main layout
  git -C "$MISE_PROJECT_ROOT" switch -q -c feature
  printf 'x\n' >>"$MISE_PROJECT_ROOT/$changed"
  export MISE_PROJECT_ROOT
  run_task "$script" local
}

# A pushed checkout whose local environment deploys cilium, which has a
# cluster suite, and flux, which has none.
verify_repository() {
  make_repository clusters/singularity/payload/kustomization.yaml >/dev/null
  printf 'resources:\n  - ../../../packages/cilium\n  - ../../../packages/flux\n' \
    >"$BATS_TEST_TMPDIR/repository/clusters/singularity/payload/kustomization.yaml"
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
  own_stub chainsaw
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
  printf 'resources: [\n' >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  commit_and_push "$MISE_PROJECT_ROOT" feature/test broken
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -ne 0 ]
  ! grep -q '^chainsaw ' "$CALLS"
}

@test "env:verify fails for an environment whose cluster has no suite" {
  MISE_PROJECT_ROOT=$(make_repository environments/bare/environment.yaml clusters/singularity/payload/kustomization.yaml)
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
  [ "$output" = 5 ]
  [ -f "$repository/.mise/flux-schemas/core/configmap_v1.json" ]
  [ -f "$repository/.mise/flux-schemas/kustomize.toolkit.fluxcd.io/kustomization_v1.json" ]
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

@test "orb:capture-stall targets <environment>-<cluster> of the selected environment when given no machine" {
  local tool
  for tool in arp dscacheutil route lsof; do
    [ -e "$stubs/$tool" ] || stub "$tool"
  done
  run "$root_directory/.mise/tasks/orb/capture-stall.sh" </dev/null
  [ "$status" -eq 0 ] || fail "$output"
  grep -qx 'orb -m local-singularity -u root ss -tnp | state= branch=' "$CALLS"
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
  own_stub orb
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

@test "env:doctor sends a kubeconfig that names an unreachable address to k0s:apply" {
  local_state
  READYZ_ERROR='dial tcp 192.168.139.53:6443: connect: no route to host' run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: no route to the address the kubeconfig names"* ]]
  [[ "$output" == *"next: mise run k0s:apply local, which writes the kubeconfig with the loopback address"* ]]
}

@test "env:doctor reports an API server that is not ready" {
  local_state
  READYZ_ERROR='the server is currently unable to handle the request' run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: the server is currently unable to handle the request"* ]]
  [[ "$output" == *"next: mise run k0s:verify"* ]]
}

@test "env:doctor tells a dead forward from a dead API server" {
  local_state
  READYZ_ERROR='dial tcp 127.0.0.1:6443: connect: connection refused' MACHINE_READYZ_OK=1 run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  api: the machine answers inside but the kubeconfig's address does not: dial tcp 127.0.0.1:6443: connect: connection refused"* ]]
  [[ "$output" == *"next: orb restart firmament"* ]]
  grep -q 'orb -m firmament sudo k0s kubectl get --raw /readyz' "$CALLS"
}

@test "env:doctor probes the machine from a terminal without stopping orb" {
  local_state
  # orb sets terminal modes; a process in a background process group that
  # does so is stopped until the probe times out.
  own_stub orb
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

# A stand-in git repository holding a copy of every contract, added to the
# index as contracts:lint reads only the files git lists.
contract_repository() {
  local repository
  repository=$(make_repository)
  cp -R "$root_directory/contracts" "$repository/"
  git -C "$repository" init -q
  git -C "$repository" add contracts
  printf '%s\n' "$repository"
}

# Plants one yq edit in a contract's sample, runs contracts:lint, and
# expects a failure that names the folder and the field.
expect_planted_value_refused() {
  local contract="$1" edit="$2" field="$3"
  MISE_PROJECT_ROOT=$(contract_repository)
  yq -i "$edit" "$MISE_PROJECT_ROOT/contracts/$contract/$contract.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -ne 0 ] || fail "accepted: $edit"
  [[ "$output" == *"$field"* ]] || fail "$output"
  [[ "$output" == *"contracts/$contract: data does not match #Contract"* ]] || fail "$output"
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

@test "contracts:lint refuses a string ssh.port in machine-hosts" {
  expect_planted_value_refused machine-hosts '.ssh.port = "22"' ssh.port
}

@test "contracts:lint refuses a malformed ssh.host_keys entry in machine-hosts" {
  expect_planted_value_refused machine-hosts '.ssh.host_keys = ["not a key line"]' ssh.host_keys
}

@test "contracts:lint accepts known_hosts key lines in ssh.host_keys" {
  MISE_PROJECT_ROOT=$(contract_repository)
  yq -i '.ssh.host_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"]' \
    "$MISE_PROJECT_ROOT/contracts/machine-hosts/machine-hosts.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "contracts:lint refuses machine-hosts without ssh.host_keys" {
  expect_planted_value_refused machine-hosts 'del(.ssh.host_keys)' ssh.host_keys
}

@test "contracts:lint refuses an empty ssh.host_keys in machine-hosts" {
  expect_planted_value_refused machine-hosts '.ssh.host_keys = []' ssh.host_keys
}

@test "contracts:lint accepts an ed25519 and an ecdsa key together in ssh.host_keys" {
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(yq '.ssh.host_keys | length' "$root_directory/contracts/machine-hosts/machine-hosts.yaml")" -ge 2 ]
}

@test "contracts:lint refuses an integer runtime_info.api_port in cluster-access" {
  expect_planted_value_refused cluster-access '.runtime_info.api_port = 6443' runtime_info.api_port
}

@test "contracts:lint refuses cluster-access without runtime_info.cilium_datapath_mode" {
  expect_planted_value_refused cluster-access 'del(.runtime_info.cilium_datapath_mode)' runtime_info.cilium_datapath_mode
}

@test "contracts:lint refuses an uppercase cluster in environment" {
  expect_planted_value_refused environment '.cluster = "Singularity"' cluster
}

@test "contracts:lint refuses a field environment does not declare" {
  expect_planted_value_refused environment '.facts = {}' facts
}

@test "contracts:lint checks a modified file as it is on disk, staged or not" {
  MISE_PROJECT_ROOT=$(contract_repository)
  git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@t commit -qm baseline
  yq -i '.cluster = "Singularity"' "$MISE_PROJECT_ROOT/contracts/environment/environment.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster"* ]] || fail "$output"
}

@test "contracts:lint names an untracked file and does not check it" {
  MISE_PROJECT_ROOT=$(contract_repository)
  printf 'facts: {}\n' >"$MISE_PROJECT_ROOT/contracts/environment/extra.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"contracts/environment/extra.yaml: untracked, not checked"* ]] || fail "$output"
}

@test "contracts:lint refuses a namespace field in package-spec" {
  expect_planted_value_refused package-spec '.namespace = "openbao"' namespace
}

@test "contracts:lint refuses a pin without a digest in package-spec" {
  expect_planted_value_refused package-spec 'del(.pin.digest)' pin.digest
}

@test "contracts:lint refuses a role in cluster-spec" {
  expect_planted_value_refused cluster-spec '.role = "workload"' role
}

@test "the Flux root lists no package, and its source is verified against the publish workflow" {
  local flux="$root_directory/clusters/singularity/flux"
  run yq -r '.resources[]' "$flux/kustomization.yaml"
  [ "$output" = "$(printf 'ocirepository.yaml\npayload.yaml\nrendered.yaml\nissuers.yaml')" ] || fail "$output"
  [ "$(yq -r '.spec.verify.provider' "$flux/ocirepository.yaml")" = cosign ]
  [ "$(yq -r '.spec.ref.tag' "$flux/ocirepository.yaml")" = '${git_commit}' ]
  [[ "$(yq -r '.spec.verify.matchOIDCIdentity[0].subject' "$flux/ocirepository.yaml")" == *'workflows/publish\.yaml@refs/heads/'* ]]
  [ "$(yq -r '.spec.path' "$flux/payload.yaml")" = ./clusters/singularity/payload ]
  [ "$(yq -r '.spec.path' "$flux/rendered.yaml")" = './clusters/singularity/rendered/${environment}' ]
  run yq -r '.resources[]' "$root_directory/clusters/singularity/payload/kustomization.yaml"
  [ "$output" = "$(printf '../../../packages/cilium\n../../../packages/flux')" ] || fail "$output"
}

@test "contracts:lint refuses a git_commit that is not 40 lowercase hex characters in cluster-access" {
  expect_planted_value_refused cluster-access '.runtime_info.git_commit = "abc123"' git_commit
}

@test "contracts:lint refuses a cluster-access contract without a git_commit" {
  expect_planted_value_refused cluster-access 'del(.runtime_info.git_commit)' git_commit
}

@test "contracts:lint refuses a binding without a tenant in bindings-spec" {
  expect_planted_value_refused bindings-spec 'del(.[0].tenant)' tenant
}

@test "contracts:lint refuses a readable seal key in private-state" {
  expect_planted_value_refused private-state '.openbao.seal_key.mode = "0644"' mode
}

@test "contracts:lint refuses a path with a directory part in private-state" {
  expect_planted_value_refused private-state '.openbao.seal_key.path = "../seal.key"' path
}

@test "contracts:lint refuses a readable snapshot in private-state" {
  expect_planted_value_refused private-state '.openbao.snapshot = {"path": "snapshot.snap", "mode": "0644", "root_fingerprint": "0000000000000000000000000000000000000000000000000000000000000000"}' mode
}

@test "contracts:lint refuses a snapshot fingerprint that is not a SHA-256 in private-state" {
  expect_planted_value_refused private-state '.openbao.snapshot = {"path": "snapshot.snap", "mode": "0600", "root_fingerprint": "abc"}' root_fingerprint
}

@test "contracts:lint accepts a snapshot and its previous generation in private-state" {
  MISE_PROJECT_ROOT=$(contract_repository)
  yq -i '.openbao.snapshot = {"path": "snapshot.snap", "mode": "0600", "root_fingerprint": "0000000000000000000000000000000000000000000000000000000000000000"} | .openbao.snapshot_previous = .openbao.snapshot' "$MISE_PROJECT_ROOT/contracts/private-state/private-state.yaml"
  run "$root_directory/.mise/tasks/contracts/lint.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "contracts:lint refuses a field private-state does not declare" {
  expect_planted_value_refused private-state '.openbao.root_token = {"path": "root.token", "mode": "0600"}' root_token
}

@test "contracts:lint refuses an environment without artifact_source" {
  expect_planted_value_refused environment 'del(.artifact_source)' artifact_source
}

@test "contracts:lint refuses the reserved cluster kind in tenant-spec" {
  expect_planted_value_refused tenant-spec '.kind = "cluster"' kind
}

@test "contracts:lint refuses a delta without a reason in delta-spec" {
  expect_planted_value_refused delta-spec 'del(.reason)' reason
}

@test "timoni is pinned to one version and locked" {
  grep -Eq '^timoni = "[0-9]+\.[0-9]+\.[0-9]+"$' "$root_directory/mise.toml"
  grep -q '^\[\[tools.timoni\]\]' "$root_directory/mise.lock"
}

@test "k0sctl is pinned to one version and locked" {
  grep -Eq '^k0sctl = "[0-9]+\.[0-9]+\.[0-9]+"$' "$root_directory/mise.toml"
  grep -q '^\[\[tools.k0sctl\]\]' "$root_directory/mise.lock"
}

@test "cosign is pinned to one version and locked" {
  grep -Eq '^cosign = "[0-9]+\.[0-9]+\.[0-9]+"$' "$root_directory/mise.toml"
  grep -q '^\[\[tools.cosign\]\]' "$root_directory/mise.lock"
}

@test "publish.yaml pins every action by commit and never uses pull_request_target" {
  workflow="$root_directory/.github/workflows/publish.yaml"
  run grep -E '^\s*-?\s*uses:' "$workflow"
  [ "$status" -eq 0 ]
  [ -z "$(grep -vE '@[0-9a-f]{40}( |$)' <<<"$output")" ] || fail "unpinned action: $output"
  run grep -q 'pull_request_target' "$workflow"
  [ "$status" -ne 0 ]
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

# A repository that binds openbao in its cluster, with the contracts the seed
# task validates the manifest against, and the local environment's contracts.
seed_repository() {
  MISE_PROJECT_ROOT=$(make_repository environments/local/environment.yaml clusters/singularity/packages.yaml clusters/singularity/openbao.yaml)
  ln -s "$root_directory/contracts" "$MISE_PROJECT_ROOT/contracts"
  printf -- '- package: openbao\n  namespace: openbao\n  tenant: platform\n' >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  printf 'operator:\n  common_name: operator\n' >"$MISE_PROJECT_ROOT/clusters/singularity/openbao.yaml"
  export MISE_PROJECT_ROOT
  record_contracts
  seed_state="$FIRMAMENT_STATE_HOME/environments/local/openbao"
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

@test "openbao:seed generates the secret files with the right modes and seeds the Secret and the ConfigMap" {
  seed_repository
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  for file in seal.key operator-ca.key operator-client.key; do
    [ "$(mode_of "$seed_state/$file")" = 600 ] || fail "$file has mode $(mode_of "$seed_state/$file")"
  done
  [ "$(mode_of "$seed_state/operator-ca.pem")" = 644 ]
  [ "$(wc -c <"$seed_state/seal.key" | tr -d ' ')" = 32 ]
  diff "$root_directory/contracts/private-state/private-state.yaml" "$seed_state/private-state.yaml"
  openssl verify -CAfile "$seed_state/operator-ca.pem" "$seed_state/operator-client.pem"
  openssl x509 -in "$seed_state/operator-client.pem" -noout -subject | grep -q 'CN *= *operator'
  grep -q 'create secret generic openbao-static-seal --from-file=seal.key=' "$CALLS"
  grep -q 'create configmap openbao-operator-ca --from-file=operator-ca.pem=' "$CALLS"
  grep -q -- '-n openbao create' "$CALLS"
}

@test "openbao:seed prints no key" {
  seed_repository
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" != *"BEGIN"* ]]
  [[ "$output" != *"$(base64 <"$seed_state/seal.key" | tr -d '\n')"* ]]
}

@test "openbao:seed run twice changes no file" {
  seed_repository
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  before=$(cd "$seed_state" && cksum seal.key operator-ca.key operator-ca.pem operator-client.key operator-client.pem private-state.yaml)
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [ "$before" = "$(cd "$seed_state" && cksum seal.key operator-ca.key operator-ca.pem operator-client.key operator-client.pem private-state.yaml)" ]
}

@test "openbao:seed stops when the manifest names a file that is gone, and creates nothing" {
  seed_repository
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  rm "$seed_state/seal.key"
  : >"$CALLS"
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"seal.key"* ]]
  [[ "$output" == *"damaged"* ]]
  [ ! -e "$seed_state/seal.key" ]
  ! grep -q 'create secret' "$CALLS"
}

@test "openbao:seed refuses a seal key that is readable by others" {
  seed_repository
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  chmod 644 "$seed_state/seal.key"
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"seal.key"* ]]
  [[ "$output" == *"mode 644"* ]]
}

@test "openbao:seed fills the files an interrupted first run left out and keeps the ones it made" {
  seed_repository
  mkdir -p "$seed_state"
  printf 'old' >"$seed_state/seal.key"
  chmod 600 "$seed_state/seal.key"
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$seed_state/seal.key")" = old ]
  [ -f "$seed_state/operator-ca.pem" ]
}

@test "openbao:seed does nothing when the cluster does not bind openbao" {
  seed_repository
  printf -- '- package: cilium\n  namespace: kube-system\n  tenant: platform\n' >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  run_task "$root_directory/.mise/tasks/openbao/seed.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"nothing to seed"* ]]
  [ ! -e "$seed_state" ]
}

@test "the names openbao:seed creates equal the names the OpenBao config mounts" {
  [ "$(cue eval -e '#SealSecretName' "$root_directory/packages/openbao/config" --out text)" = "$(sed -n 's/^readonly seal_secret=//p' "$root_directory/.mise/tasks/openbao/seed.sh")" ]
  [ "$(cue eval -e '#OperatorCAConfigMapName' "$root_directory/packages/openbao/config" --out text)" = "$(sed -n 's/^readonly operator_ca_configmap=//p' "$root_directory/.mise/tasks/openbao/seed.sh")" ]
}

@test "network-policy:verify passes when the consumer reaches the provider's port and the default namespace does not" {
  record_contracts
  run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  grep -q -- '-n cert-manager run .*nc -z -w 8 \$address 8443' "$CALLS"
  grep -q -- 'for address in 10.0.0.5;' "$CALLS"
  [[ "$output" == *"cert-manager reaches port 8443 of openbao"* ]]
  [[ "$output" == *"default does not reach port 8443 of openbao"* ]]
}

@test "network-policy:verify probes every consumer of every provider, and the default namespace once per provider port" {
  printf '#!/usr/bin/env bash\ncat <<JSON\n{"namespaces":{"db":{"mode":"full","provides":[{"capability":"sql","port":5432,"protocol":"TCP","consumers":["web","api"]}],"hostPorts":[]},"cache":{"mode":"full","provides":[{"capability":"kv","port":6379,"protocol":"TCP","consumers":["web"]}],"hostPorts":[]}}}\nJSON\n' >"$stubs/cue"
  chmod +x "$stubs/cue"
  printf '{"items":[{"status":{"podIP":"10.0.0.6","hostIP":"192.168.0.2"}}]}' >"$BATS_TEST_TMPDIR/pods.json"
  PODS="$BATS_TEST_TMPDIR/pods.json" run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"ok: web reaches port 5432 of db"* ]]
  [[ "$output" == *"ok: api reaches port 5432 of db"* ]]
  [[ "$output" == *"ok: web reaches port 6379 of cache"* ]]
  [ "$(grep -c -- '-n default run .*nc -z' "$CALLS")" -eq 2 ]
}

@test "network-policy:verify fails when no namespace has a consumer" {
  printf '#!/usr/bin/env bash\necho "{\\"namespaces\\":{}}"\n' >"$stubs/cue"
  chmod +x "$stubs/cue"
  run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to check"* ]]
}

@test "network-policy:verify checks that the default namespace is blocked from a tenant pod and a tenant pod from the API server" {
  record_contracts
  run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  grep -q -- '-n cv run' "$CALLS"
  [[ "$output" == *"default is blocked from the cv pod 10.0.0.9 on port 44100"* ]]
  [[ "$output" == *"a pod in cv cannot reach the API server"* ]]
}

@test "network-policy:verify asks Hubble for the verdict of every probe" {
  record_contracts
  run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  grep -q -- 'exec ds/cilium -c cilium-agent -- hubble observe --from-pod cert-manager/policy-probe-[0-9]* --verdict FORWARDED --to-namespace openbao' "$CALLS"
  grep -q -- 'hubble observe --from-pod default/policy-probe-[0-9]* --verdict DROPPED --to-namespace openbao' "$CALLS"
  grep -q -- 'hubble observe --from-pod default/policy-probe-[0-9]* --verdict FORWARDED --to-port 53' "$CALLS"
  grep -q -- 'hubble observe --from-pod default/policy-probe-[0-9]* --verdict DROPPED --to-ip 10.0.0.9 --to-port 44100' "$CALLS"
  grep -q -- 'hubble observe --from-pod cv/policy-probe-[0-9]* --verdict DROPPED' "$CALLS"
}

@test "network-policy:verify fails when a blocked probe has no dropped flow, so a routing fault cannot pass for a policy drop" {
  record_contracts
  stub_sleep
  NP_NO_FLOW=DROPPED run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"Hubble recorded no DROPPED flow from default/policy-probe-"* ]]
}

@test "network-policy:verify fails when an allowed probe has no forwarded flow" {
  record_contracts
  stub_sleep
  NP_NO_FLOW=FORWARDED run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"Hubble recorded no FORWARDED flow from cert-manager/policy-probe-"* ]]
}

@test "network-policy:verify fails when a tenant pod reaches the API server" {
  record_contracts
  NP_TENANT_API='{"major":"1"}exit=0' run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"not blocked from the API server"* ]]
}

@test "network-policy:verify fails when the default namespace pod fails for another reason than a blocked connection" {
  record_contracts
  NP_PROVIDER_DENIED='error: pod did not start' run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed for another reason than a blocked connection"* ]]
}

@test "network-policy:verify fails when the pod outside the allowed namespace reaches the provider" {
  record_contracts
  NP_PROVIDER_DENIED='exit=0' run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"default namespace reached port 8443 of openbao"* ]]
}

@test "network-policy:verify fails when a pod in the default namespace cannot resolve names" {
  record_contracts
  NP_RESOLVED='exit=1' run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve a name"* ]]
}

@test "network-policy:verify fails when the consumer cannot reach OpenBao" {
  record_contracts
  NP_ALLOWED='exit=1' run_task "$root_directory/.mise/tasks/network-policy/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not reach port 8443 of openbao"* ]]
}

@test "tenant:verify checks a copy with the real signer, a copy with another signer and a copy of an unsigned chart" {
  run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"ok: Flux verifies cv, refuses it when another signer is required, and refuses an unsigned chart"* ]]
  [ "$(jq -s 'length' "$BATS_TEST_TMPDIR/applied")" -eq 3 ]
  jq -s -e 'map(select(.metadata.name | startswith("test-control-"))) | .[0] | .spec.verify.matchOIDCIdentity[0].subject == "subject" and .spec.url == "oci://registry.test/cv"' "$BATS_TEST_TMPDIR/applied"
  jq -s -e 'map(select(.metadata.name | startswith("test-wrong-signer-"))) | .[0] | .spec.verify.matchOIDCIdentity[0].subject | startswith("^https://github\\.com/firmament-test/")' "$BATS_TEST_TMPDIR/applied"
  jq -s -e 'map(select(.metadata.name | startswith("test-unsigned-"))) | .[0] | .spec.url == "oci://ghcr.io/insuperposition/charts/cv-unsigned" and (.spec.ref.digest | startswith("sha256:")) and .spec.verify.matchOIDCIdentity[0].subject == "subject"' "$BATS_TEST_TMPDIR/applied"
  jq -s -e 'all(.metadata.labels["firmament.test/tenant-verify"] == "true")' "$BATS_TEST_TMPDIR/applied"
  grep -q -- '--for=condition=SourceVerified=True .*test-control-' "$CALLS"
  grep -q -- '--for=condition=SourceVerified=False .*test-wrong-signer-' "$CALLS"
  grep -q -- '--for=condition=SourceVerified=False .*test-unsigned-' "$CALLS"
}

@test "tenant:verify fails when the copy with the real signer does not verify, so a refusal cannot be a network fault" {
  TV_FAIL='SourceVerified=True' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"source test-control-"*"never had SourceVerified=True"* ]]
  ! grep -q 'test-wrong-signer' "$CALLS"
}

@test "tenant:verify fails when a chart that demands another signer is accepted" {
  TV_FAIL='SourceVerified=False ocirepositories.source.toolkit.fluxcd.io/test-wrong-signer' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"source test-wrong-signer-"*"never had SourceVerified=False"* ]]
}

@test "tenant:verify fails when an unsigned chart is accepted" {
  TV_FAIL='SourceVerified=False ocirepositories.source.toolkit.fluxcd.io/test-unsigned' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"source test-unsigned-"*"never had SourceVerified=False"* ]]
}

@test "tenant:verify deletes the temporary sources before it starts and after it fails" {
  TV_FAIL='SourceVerified=True' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [ "$(grep -c 'delete ocirepositories.source.toolkit.fluxcd.io -l firmament.test/tenant-verify' "$CALLS")" -eq 2 ]
}

@test "tenant:verify has nothing to check when no chart source must be signed" {
  OCI_SOURCES='{"items":[{"metadata":{"name":"flux"},"spec":{}}]}' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to check"* ]]
}

@test "tenant:verify checks that a namespace no binding names stays denied, with a Hubble drop" {
  run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"ok: a namespace no binding names stays denied: default cannot reach port 8080 of test-retained-"* ]]
  grep -q -- 'create namespace test-retained-' "$CALLS"
  grep -q -- 'label namespace test-retained-.* firmament.test/tenant-verify=true' "$CALLS"
  grep -q -- 'hubble observe --from-pod default/policy-probe-[0-9]* --verdict DROPPED --to-ip 10.0.0.12 --to-port 8080' "$CALLS"
  [ "$(grep -c 'delete namespaces -l firmament.test/tenant-verify' "$CALLS")" -eq 2 ]
}

@test "tenant:verify fails when the default namespace reaches a namespace no binding names" {
  NP_PROVIDER_DENIED='exit=0' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"reached port 8080 of test-retained-"* ]]
}

@test "tenant:verify fails when the pod in the unbound namespace does not listen, so a refusal cannot be an empty port" {
  TV_LISTENING='exit=1' run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not listen on port 8080"* ]]
}

@test "tenant:verify fails when a blocked connection to the unbound namespace has no dropped flow" {
  stub_sleep
  NP_NO_FLOW=DROPPED run_task "$root_directory/.mise/tasks/tenant/verify.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"Hubble recorded no DROPPED flow from default/policy-probe-"* ]]
}

@test "the traffic permit is a labelled clusterwide policy that opens exactly the two fixture namespaces" {
  local permit="$root_directory/.mise/traffic/permit.yaml"
  [ "$(yq -r '.kind' "$permit")" = CiliumClusterwideNetworkPolicy ]
  [ "$(yq -r '.metadata.name' "$permit")" = "$(sed -n 's/^readonly TRAFFIC_PERMIT_NAME=//p' "$root_directory/.mise/lib.sh")" ]
  [ "$(yq -r '.metadata.labels["firmament.test/traffic-fixtures"]' "$permit")" = true ]
  [ "$(yq -r '.spec.endpointSelector.matchExpressions[0].values | sort | join(",")' "$permit")" = "cilium-test-1,traffic-probe" ]
  [ "$(yq -r '.spec.ingress[0].fromEntities[0] + " " + .spec.egress[0].toEntities[0]' "$permit")" = "all all" ]
}

@test "cilium:traffic-start removes the permit when the start fails, so a crashed run leaves none" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  printf '{"Statuses":null}\n' >"$BATS_TEST_TMPDIR/none.json"
  FORTIO_STATUS="$BATS_TEST_TMPDIR/none.json" FIRMAMENT_FORTIO_START_TIMEOUT=1 run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [ "$(grep -c 'delete ciliumclusterwidenetworkpolicies.cilium.io -l firmament.test/traffic-fixtures' "$CALLS")" -eq 2 ]
}

@test "cilium:traffic-start keeps the permit when the start succeeds" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -eq 0 ]
  [ "$(grep -c 'delete ciliumclusterwidenetworkpolicies' "$CALLS")" -eq 1 ]
}

@test "cilium:traffic-start fails when the cilium-cli did not deploy into the namespace the permit names" {
  export PODS="$BATS_TEST_TMPDIR/pods.json"
  pods uid-agent >"$PODS"
  CILIUM_TEST_NAMESPACE_MISSING=1 run_task "$root_directory/.mise/tasks/cilium/traffic-start.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not deploy into cilium-test-1, the namespace the traffic permit names"* ]]
  ! grep -q 'fortio/rest/run' "$CALLS"
}

@test "cilium:traffic-check fails, naming the denied namespaces, when the traffic permit is gone" {
  started_traffic
  PERMIT_MISSING=1 run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"the traffic permit traffic-fixtures-permit is gone, so the clusterwide default deny blocks traffic-probe and cilium-test-1"* ]]
  ! grep -q '^cilium ' "$CALLS"
  ! grep -q '/fortio/rest/stop' "$CALLS"
}

@test "cilium:traffic-check keeps the permit when the traffic did not survive" {
  started_traffic
  export FORTIO_RESULT="$BATS_TEST_TMPDIR/bad.json"
  fortio_result '.RetCodes = {"200": 1990, "-1": 10}' >"$FORTIO_RESULT"
  run_task "$root_directory/.mise/tasks/cilium/traffic-check.sh" local
  [ "$status" -ne 0 ]
  ! grep -q 'delete ciliumclusterwidenetworkpolicies' "$CALLS"
}
