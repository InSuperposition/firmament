#!/usr/bin/env bats

load stubs.bash

setup() {
  setup_stubs
  # shellcheck source=../lib.sh
  source "$root_directory/.mise/lib.sh"
}

@test "resolves an existing environment to its OpenTofu root" {
  run environment_directory local
  [ "$status" -eq 0 ]
  [ "$output" = "$root_directory/environment/local" ]
}

@test "rejects an environment without a directory" {
  run environment_directory nowhere
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown environment 'nowhere'"* ]]
}

@test "keeps each environment's state under FIRMAMENT_STATE_HOME" {
  run state_directory local
  [ "$output" = "$FIRMAMENT_STATE_HOME/environment/local" ]
}

@test "refuses to guess a state directory outside mise" {
  unset FIRMAMENT_STATE_HOME
  run state_directory local
  [ "$status" -ne 0 ]
  [[ "$output" == *"FIRMAMENT_STATE_HOME is unset"* ]]
}

@test "runs tofu in the environment root with its state directory and branch" {
  tofu_in_environment local plan -input=false
  run cat "$CALLS"
  [ "$output" = "tofu -chdir=$root_directory/environment/local plan -input=false | state=$FIRMAMENT_STATE_HOME/environment/local branch=feature/test" ]
}

@test "follows the checked-out branch when the caller names none" {
  unset FIRMAMENT_GIT_BRANCH
  MISE_PROJECT_ROOT="$BATS_TEST_TMPDIR/repository"
  git init -q -b feature/checked-out "$MISE_PROJECT_ROOT"
  run git_branch
  [ "$status" -eq 0 ]
  [ "$output" = feature/checked-out ]
}

@test "refuses to guess a branch on a detached HEAD" {
  unset FIRMAMENT_GIT_BRANCH
  MISE_PROJECT_ROOT="$BATS_TEST_TMPDIR/repository"
  git init -q "$MISE_PROJECT_ROOT"
  git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
  git -C "$MISE_PROJECT_ROOT" checkout -q --detach
  mkdir -p "$MISE_PROJECT_ROOT/environment/local"
  run tofu_in_environment local plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD is detached; set FIRMAMENT_GIT_BRANCH"* ]]
  [ ! -e "$CALLS" ]
}

@test "creates no state directory for an environment that does not exist" {
  run init_environment nowhere
  [ "$status" -ne 0 ]
  [ ! -e "$FIRMAMENT_STATE_HOME/environment/nowhere" ]
  [ ! -e "$CALLS" ]
}

@test "points the backend at the environment's state file" {
  init_environment local
  [ -d "$FIRMAMENT_STATE_HOME/environment/local" ]
  run cat "$CALLS"
  [[ "$output" == *"init -input=false -reconfigure -lockfile=readonly -backend-config=path=$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate"* ]]
}

@test "waits for Cilium, then Flux and the Cilium release, then Cilium again, then the nodes" {
  wait_for_cluster local
  run grep -v '^tofu ' "$CALLS"
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig status --wait --wait-duration=10m --interactive=false" ]
  [ "${lines[1]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=10m" ]
  [ "${lines[2]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait --for=condition=Ready helmrelease/cilium --timeout=10m" ]
  [ "${lines[3]%% |*}" = "${lines[0]%% |*}" ]
  [ "${lines[4]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig wait --for=condition=Ready node --all --timeout=5m" ]
}

@test "stops waiting for the node once one has registered" {
  NODES=node/firmament wait_for_node /kubeconfig 5 0
  run grep -c 'get nodes -o name' "$CALLS"
  [ "$output" = 1 ]
}

@test "gives up when no node registers within the timeout" {
  run wait_for_node /kubeconfig 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no node registered with the API server within 0s"* ]]
}

@test "initializes a directory without a backend" {
  init_offline /modules/a
  run cat "$CALLS"
  [ "${output%% |*}" = "tofu -chdir=/modules/a init -backend=false -input=false -reconfigure -lockfile=readonly" ]
}

@test "finds each module and environment holding an OpenTofu test suite, once" {
  MISE_PROJECT_ROOT=$(make_repository modules/a/tests/unit.tftest.hcl modules/a/tests/more.tftest.hcl \
    modules/b/tests/unit.bats environment/e/tests/wiring.tftest.hcl)
  run tofu_test_directories
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$MISE_PROJECT_ROOT/environment/e" ]
  [ "${lines[1]}" = "$MISE_PROJECT_ROOT/modules/a" ]
}

@test "finds no test directories when no suite exists" {
  MISE_PROJECT_ROOT=$(make_repository modules/b/tests/unit.bats)
  run tofu_test_directories
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stops before tofu when the environment does not exist" {
  run tofu_in_environment nowhere plan
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
}

@test "treats an empty XDG_STATE_HOME as unset" {
  run env -u FIRMAMENT_STATE_HOME XDG_STATE_HOME= "$real_mise" env --json -C "$root_directory"
  [ "$status" -eq 0 ]
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = "$HOME/.local/state/firmament" ]
}

@test "honors a FIRMAMENT_STATE_HOME set by the caller" {
  run env FIRMAMENT_STATE_HOME=/custom "$real_mise" env --json -C "$root_directory"
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = /custom ]
}

@test "points KUBECONFIG at the local cluster from the root and inside environment/local" {
  root=$(env -u KUBECONFIG "$real_mise" env --json -C "$root_directory" | jq -r .KUBECONFIG)
  local_environment=$(env -u KUBECONFIG "$real_mise" env --json -C "$root_directory/environment/local" | jq -r .KUBECONFIG)
  [ "$root" = "$FIRMAMENT_STATE_HOME/environment/local/admin.kubeconfig" ]
  [ "$local_environment" = "$root" ]
}
