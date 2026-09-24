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
  [[ "$output" == *"init -input=false -reconfigure -backend-config=path=$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate"* ]]
}

@test "waits for Cilium, then the charts, then Cilium again, then the nodes" {
  charts '{"items": []}'
  wait_for_cluster local
  run grep -v '^tofu ' "$CALLS"
  [ "${lines[0]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig status --wait --wait-duration=10m --interactive=false" ]
  [ "${lines[1]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n kube-system get charts.helm.k0sproject.io -o json" ]
  [ "${lines[2]%% |*}" = "${lines[0]%% |*}" ]
  [ "${lines[3]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig wait --for=condition=Ready node --all --timeout=5m" ]
}

# Writes a chart list for the kubectl stub. Each chart is given as
# "<values> <values k0s last reconciled> <status version> <status error>".
charts() {
  export CHARTS="$BATS_TEST_TMPDIR/charts.json"
  printf '%s' "$1" >"$CHARTS"
}

chart() {
  local values="$1" reconciled="$2" version="$3" error="$4" hash
  hash=$(printf '%s' "cilium$reconciled" | shasum -a 256)
  jq -n --arg values "$values" --arg hash "${hash%% *}" --arg version "$version" --arg error "$error" \
    '{metadata: {name: "k0s-addon-chart-cilium"}, spec: {releaseName: "cilium", values: $values, version: "1.20.2"},
      status: ({valuesHash: $hash, version: $version} + (if $error == "" then {} else {error: $error} end))}'
}

@test "reports a chart whose current spec is installed as ready" {
  charts "$(chart 'a: 1' 'a: 1' 1.20.2 '' | jq -s '{items: .}')"
  run chart_states /kubeconfig
  [ "$output" = "ready k0s-addon-chart-cilium" ]
}

@test "reports a chart whose values changed since the last reconcile as pending" {
  charts "$(chart 'a: 2' 'a: 1' 1.20.2 '' | jq -s '{items: .}')"
  run chart_states /kubeconfig
  [ "$output" = "pending k0s-addon-chart-cilium" ]
}

@test "reports a chart whose version changed since the last reconcile as pending" {
  charts "$(chart 'a: 1' 'a: 1' 1.19.0 '' | jq -s '{items: .}')"
  run chart_states /kubeconfig
  [ "$output" = "pending k0s-addon-chart-cilium" ]
}

@test "reports a chart whose current spec failed to install as failed" {
  charts "$(chart 'a: 1' 'a: 1' 1.20.2 'upgrade failed' | jq -s '{items: .}')"
  run chart_states /kubeconfig
  [ "$output" = "failed k0s-addon-chart-cilium" ]
}

@test "keeps waiting on an old error once the spec has changed" {
  charts "$(chart 'a: 2' 'a: 1' 1.20.2 'upgrade failed' | jq -s '{items: .}')"
  run chart_states /kubeconfig
  [ "$output" = "pending k0s-addon-chart-cilium" ]
}

@test "stops waiting at the first failed chart and prints the charts" {
  charts "$(chart 'a: 1' 'a: 1' 1.20.2 'upgrade failed' | jq -s '{items: .}')"
  run wait_for_charts /kubeconfig 600 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not install a Helm chart"* ]]
  grep -q 'get charts.helm.k0sproject.io -o yaml' "$CALLS"
}

@test "gives up on a pending chart at the timeout" {
  charts "$(chart 'a: 2' 'a: 1' 1.20.2 '' | jq -s '{items: .}')"
  run wait_for_charts /kubeconfig 0 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not reconcile the Helm charts within 0s"* ]]
}

@test "fails instead of guessing when the chart list is not valid" {
  charts 'not json'
  run chart_states /kubeconfig
  [ "$status" -ne 0 ]
}

@test "matches the valuesHash k0s records for a live chart" {
  # Values and valuesHash copied from a k0s 1.36 Chart status.
  charts '{"items": [{"metadata": {"name": "k0s-addon-chart-x"}, "spec": {"releaseName": "x", "values": "a: 1\n", "version": "1"},
    "status": {"valuesHash": "'"$(printf 'xa: 1\n' | shasum -a 256 | cut -d' ' -f1)"'", "version": "1"}}]}'
  run chart_states /kubeconfig
  [ "$output" = "ready k0s-addon-chart-x" ]
}

@test "initializes a directory without a backend" {
  init_offline /modules/a
  run cat "$CALLS"
  [ "${output%% |*}" = "tofu -chdir=/modules/a init -backend=false -input=false -reconfigure" ]
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
