#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load stubs.bash

setup() {
  setup_stubs
  export TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local"
  # shellcheck source=../lib.sh
  source "$root_directory/.mise/lib.sh"
}

@test "resolves an existing environment to its data directory" {
  run environment_directory
  [ "$status" -eq 0 ]
  [ "$output" = "$root_directory/environments/local" ]
}

@test "rejects an environment without a directory" {
  MISE_ENV=nowhere run environment_directory
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown environment 'nowhere'"* ]]
}

@test "selects local when MISE_ENV is unset, and the name MISE_ENV gives otherwise" {
  run selected_environment
  [ "$output" = local ]
  MISE_ENV=staging run selected_environment
  [ "$output" = staging ]
}

@test "refuses an environment name that is not lowercase letters, digits and -" {
  local name
  for name in Local staging,local 1x -x ../x 'a b' a_b; do
    MISE_ENV="$name" run selected_environment
    [ "$status" -ne 0 ] || fail "accepted '$name'"
    [[ "$output" == *"invalid environment name '$name' in MISE_ENV"* ]]
  done
}

@test "checks the environment before it names it" {
  run require_environment
  [ "$status" -eq 0 ]
  [ "$output" = local ]
  MISE_ENV=nowhere TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/nowhere" run require_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown environment 'nowhere'"* ]]
}

@test "refuses a state directory that belongs to another environment" {
  mkdir -p "$root_directory/environments/other-test"
  MISE_ENV=other-test run require_environment
  rmdir "$root_directory/environments/other-test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not belong to environment 'other-test'"* ]]
}

@test "refuses to guess a state directory outside mise" {
  unset TF_VAR_state_directory
  run require_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"TF_VAR_state_directory is unset"* ]]
}

@test "runs tofu in one root with the environment's state directory and branch" {
  tofu_in_root kubernetes-k0s plan -input=false
  run cat "$CALLS"
  [ "$output" = "tofu -chdir=$root_directory/tofu/roots/kubernetes-k0s plan -input=false | state=$FIRMAMENT_STATE_HOME/environments/local branch=feature/test" ]
}

@test "tells a root the name of the environment it runs for" {
  tofu() { printf '%s' "$TF_VAR_environment"; }
  run tofu_in_root machine-orb plan
  [ "$output" = local ]
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
  mkdir -p "$MISE_PROJECT_ROOT/environments/local"
  run tofu_in_root machine-orb plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"HEAD is detached; set FIRMAMENT_GIT_BRANCH"* ]]
  [ ! -e "$CALLS" ]
}

@test "accepts a branch name made of letters, digits and . _ / -" {
  run check_branch_name feat/flux-bootstrap_2.x
  [ "$status" -eq 0 ]
}

@test "rejects branch names the bootstrap shell or Git would misread" {
  local name
  for name in 'main;touch x' '$(id)' 'a b' 'feature..x' '-x' 'x.lock' 'x/'; do
    run check_branch_name "$name"
    [ "$status" -ne 0 ] || fail "accepted '$name'"
    [[ "$output" == *"invalid branch name '$name'"* ]]
  done
}

@test "refuses a caller-named branch that is not a valid name" {
  FIRMAMENT_GIT_BRANCH='main;touch x' run tofu_in_root machine-orb plan
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
}

@test "prints the revision Flux reports for origin's branch tip" {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environments/local/environment.yaml)
  run flux_revision feature/test
  [ "$status" -eq 0 ]
  [ "$output" = "refs/heads/feature/test@sha1:$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)" ]
}

@test "fails for a branch that origin does not have" {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environments/local/environment.yaml)
  run flux_revision feature/other
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/other does not exist; push the branch first"* ]]
}

@test "creates no state directory for an environment that does not exist" {
  MISE_ENV=nowhere run init_root machine-orb
  [ "$status" -ne 0 ]
  [ ! -e "$FIRMAMENT_STATE_HOME/environments/nowhere" ]
  [ ! -e "$CALLS" ]
}

@test "refuses an empty state file before running tofu" {
  local root
  for root in machine-orb kubernetes-k0s bootstrap-flux; do
    mkdir -p "$FIRMAMENT_STATE_HOME/environments/local"
    : >"$FIRMAMENT_STATE_HOME/environments/local/$root.tfstate"
    run init_root "$root"
    [ "$status" -ne 0 ] || fail "$root accepted an empty state file"
    [[ "$output" == *"$FIRMAMENT_STATE_HOME/environments/local/$root.tfstate is empty"* ]]
    [[ "$output" == *"$root.tfstate.backup"* ]]
    rm "$FIRMAMENT_STATE_HOME/environments/local/$root.tfstate"
  done
  [ ! -e "$CALLS" ]
}

@test "points each root's backend at its own state file in the environment's state directory" {
  local root
  for root in machine-orb kubernetes-k0s bootstrap-flux; do
    init_root "$root"
    grep -q "^tofu -chdir=$root_directory/tofu/roots/$root init -input=false -reconfigure -lockfile=readonly -backend-config=path=$FIRMAMENT_STATE_HOME/environments/local/$root.tfstate " "$CALLS" ||
      fail "$root: $(cat "$CALLS")"
  done
  [ -d "$FIRMAMENT_STATE_HOME/environments/local" ]
}

@test "waits for Cilium, then Flux and the Cilium release, then Cilium again, then the nodes" {
  wait_for_cluster
  run grep -v '^tofu ' "$CALLS"
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig status --wait --wait-duration=10m --interactive=false" ]
  [ "${lines[1]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=10m" ]
  [ "${lines[2]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig -n flux-system wait --for=create --for=condition=Ready helmrelease/cilium --timeout=10m" ]
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

@test "counts the cilium release current when it runs the ConfigMap's values in any key order" {
  CILIUM_VALUES=$'# Chart values.\nb:\n  d: 2\n  c: 1\na: "1.20"' \
    RELEASE_VALUES=$'a: "1.20"\nb:\n  c: 1\n  d: 2' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -eq 0 ]
}

@test "counts the cilium release current when it runs the ConfigMap's values with the network policy's merged over them" {
  CILIUM_VALUES=$'a: "1.20"\nextraConfig:\n  keep: yes' \
    CILIUM_VALUES_POLICY=$'extraConfig:\n  allow-localhost: policy' \
    RELEASE_VALUES=$'a: "1.20"\nextraConfig:\n  allow-localhost: policy\n  keep: yes' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -eq 0 ] || fail "$output"
}

@test "counts the cilium release current when it runs the gateway's values merged over the policy's and the ConfigMap's" {
  CILIUM_VALUES=$'a: "1.20"\nextraConfig:\n  keep: yes' \
    CILIUM_VALUES_POLICY=$'extraConfig:\n  allow-localhost: policy' \
    CILIUM_VALUES_GATEWAY=$'gatewayAPI:\n  enabled: true\n  hostNetwork:\n    enabled: true' \
    RELEASE_VALUES=$'a: "1.20"\nextraConfig:\n  allow-localhost: policy\n  keep: yes\ngatewayAPI:\n  enabled: true\n  hostNetwork:\n    enabled: true' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -eq 0 ] || fail "$output"
}

@test "waits while the cilium release lacks the gateway's values" {
  CILIUM_VALUES='a: 1' CILIUM_VALUES_GATEWAY=$'gatewayAPI:\n  enabled: true' RELEASE_VALUES='a: 1' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -ne 0 ]
}

@test "waits while the cilium release lacks the network policy's values" {
  CILIUM_VALUES='a: 1' CILIUM_VALUES_POLICY=$'extraConfig:\n  allow-localhost: policy' RELEASE_VALUES='a: 1' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -ne 0 ]
}

@test "waits while the cilium release runs other values than the ConfigMap" {
  CILIUM_VALUES='a: 2' RELEASE_VALUES='a: 1' run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"the cilium release does not run the values in the cilium-values ConfigMap after 0s"* ]]
}

# Gives cilium_values_deployed a repository whose Cilium HelmRelease lists the
# values sources in $1 (a YAML flow sequence), in that order.
cilium_release_listing() {
  MISE_PROJECT_ROOT="$BATS_TEST_TMPDIR/listing"
  mkdir -p "$MISE_PROJECT_ROOT/packages/cilium"
  printf 'spec:\n  valuesFrom: %s\n' "$1" >"$MISE_PROJECT_ROOT/packages/cilium/helmrelease.yaml"
}

@test "merges the values sources in the order the HelmRelease lists them" {
  cilium_release_listing '[{kind: ConfigMap, name: cilium-values}, {kind: ConfigMap, name: cilium-values-gateway, optional: true}, {kind: ConfigMap, name: cilium-values-policy, optional: true}]'
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml"},{"kind":"ConfigMap","name":"cilium-values-gateway","valuesKey":"values.yaml","optional":true},{"kind":"ConfigMap","name":"cilium-values-policy","valuesKey":"values.yaml","optional":true}]' \
    CILIUM_VALUES='a: 1' CILIUM_VALUES_GATEWAY='who: gateway' CILIUM_VALUES_POLICY='who: policy' RELEASE_VALUES=$'a: 1\nwho: policy' \
    run cilium_values_deployed /kubeconfig
  [ "$status" -eq 0 ] || fail "$output"
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml"},{"kind":"ConfigMap","name":"cilium-values-gateway","valuesKey":"values.yaml","optional":true},{"kind":"ConfigMap","name":"cilium-values-policy","valuesKey":"values.yaml","optional":true}]' \
    CILIUM_VALUES='a: 1' CILIUM_VALUES_GATEWAY='who: gateway' CILIUM_VALUES_POLICY='who: policy' RELEASE_VALUES=$'a: 1\nwho: gateway' \
    run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "never counts the release current when the live HelmRelease lists other sources than the repository" {
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml"}]' \
    CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values-policy","valuesKey":"values.yaml","optional":true},{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml"},{"kind":"ConfigMap","name":"cilium-values-gateway","valuesKey":"values.yaml","optional":true}]' \
    CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "never counts the release current when the HelmRelease cannot be read" {
  CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' HELMRELEASE_ERROR='connection refused' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "refuses a values source that is not a ConfigMap key values.yaml, even when the live release lists it too" {
  cilium_release_listing '[{kind: ConfigMap, name: cilium-values}, {kind: Secret, name: cilium-values-policy, optional: true}]'
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml"},{"kind":"Secret","name":"cilium-values-policy","valuesKey":"values.yaml","optional":true}]' \
    CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
  cilium_release_listing '[{kind: ConfigMap, name: cilium-values, valuesKey: other.yaml}]'
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"other.yaml"}]' \
    CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "counts the release current when the live HelmRelease spells the defaults out" {
  HELMRELEASE_VALUES_FROM='[{"kind":"ConfigMap","name":"cilium-values","valuesKey":"values.yaml","optional":false},{"kind":"ConfigMap","name":"cilium-values-policy","valuesKey":"values.yaml","optional":true},{"kind":"ConfigMap","name":"cilium-values-gateway","valuesKey":"values.yaml","optional":true}]' \
    CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' run cilium_values_deployed /kubeconfig
  [ "$status" -eq 0 ] || fail "$output"
}

@test "never counts an overlay it could not read as absent" {
  CILIUM_VALUES='a: 1' RELEASE_VALUES='a: 1' CILIUM_VALUES_GATEWAY_ERROR='connection refused' \
    run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "never counts an empty cilium-values ConfigMap as deployed" {
  CILIUM_VALUES='' RELEASE_VALUES='' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "reads the kubeconfig path from the cluster-access contract" {
  record_contracts /some/admin.kubeconfig
  run environment_kubeconfig
  [ "$status" -eq 0 ]
  [ "$output" = /some/admin.kubeconfig ]
}

@test "prints a contract object as JSON" {
  run contract_field cluster-access.yaml .runtime_info
  [ "$status" -eq 0 ]
  [ "$(jq -r .cilium_datapath_mode <<<"$output")" = netkit ]
}

@test "fails for a contract the environment has no file for, instead of printing nothing" {
  forget_contract cluster-access.yaml
  run environment_kubeconfig
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' has no .kubeconfig_path in cluster-access.yaml; apply it first"* ]]
  run contract_field_or_empty cluster-access.yaml .kubeconfig_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refuses to read a contract for an environment that does not exist" {
  MISE_ENV=nowhere run contract_field_or_empty machine-hosts.yaml .name
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown environment 'nowhere'"* ]]
}

@test "initializes a directory without a backend" {
  init_offline /tofu/modules/a
  run cat "$CALLS"
  [ "${output%% |*}" = "tofu -chdir=/tofu/modules/a init -backend=false -input=false -reconfigure -lockfile=readonly" ]
}

@test "finds each module and root holding an OpenTofu test suite, once" {
  MISE_PROJECT_ROOT=$(make_repository tofu/modules/a/tests/unit.tftest.hcl tofu/modules/a/tests/more.tftest.hcl \
    tofu/modules/b/tests/unit.bats tofu/roots/r/tests/wiring.tftest.hcl)
  run tofu_test_directories
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$MISE_PROJECT_ROOT/tofu/modules/a" ]
  [ "${lines[1]}" = "$MISE_PROJECT_ROOT/tofu/roots/r" ]
}

@test "fails when no OpenTofu test suite exists" {
  MISE_PROJECT_ROOT=$(make_repository tofu/modules/b/tests/unit.bats)
  run tofu_test_directories
  [ "$status" -ne 0 ]
  [[ "$output" == *"no OpenTofu test suite"* ]]
}

@test "stops before tofu when the environment does not exist" {
  MISE_ENV=nowhere run tofu_in_root machine-orb plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown environment 'nowhere'"* ]]
  [ ! -e "$CALLS" ]
}

@test "treats an empty XDG_STATE_HOME as unset" {
  run --separate-stderr env -u FIRMAMENT_STATE_HOME XDG_STATE_HOME= "$real_mise" env --json -C "$root_directory"
  [ "$status" -eq 0 ]
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = "$HOME/.local/state/firmament" ]
}

@test "honors a FIRMAMENT_STATE_HOME set by the caller" {
  run --separate-stderr env FIRMAMENT_STATE_HOME=/custom "$real_mise" env --json -C "$root_directory"
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = /custom ]
}

@test "derives the state directory and kubeconfig from MISE_ENV, local when it is unset" {
  local values
  values=$(env -u MISE_ENV -u KUBECONFIG -u TF_VAR_state_directory "$real_mise" env --json -C "$root_directory")
  [ "$(jq -r .TF_VAR_state_directory <<<"$values")" = "$FIRMAMENT_STATE_HOME/environments/local" ]
  [ "$(jq -r .KUBECONFIG <<<"$values")" = "$FIRMAMENT_STATE_HOME/environments/local/admin.kubeconfig" ]
}

@test "derives all three values for the environment MISE_ENV names" {
  local values
  values=$(env -u KUBECONFIG -u TF_VAR_state_directory MISE_ENV=staging "$real_mise" env --json -C "$root_directory")
  [ "$(jq -r .TF_VAR_state_directory <<<"$values")" = "$FIRMAMENT_STATE_HOME/environments/staging" ]
  [ "$(jq -r .KUBECONFIG <<<"$values")" = "$FIRMAMENT_STATE_HOME/environments/staging/admin.kubeconfig" ]
}

@test "environments hold data only: no environment has a mise.toml" {
  run find "$root_directory/environments" -name 'mise*.toml'
  [ -z "$output" ]
}

@test "waits for a process to listen on a local port" {
  local port=$((20000 + RANDOM % 20000))
  nc -l 127.0.0.1 "$port" >/dev/null &
  run wait_for_local_port "$!" "$port" 10
  [ "$status" -eq 0 ]
}

@test "fails when the process meant to listen on a local port exits" {
  true &
  local pid=$!
  wait "$pid"
  run wait_for_local_port "$pid" 1 10
  [ "$status" -ne 0 ]
  [[ "$output" == *"the process that should listen on local port 1 exited"* ]]
}

@test "fails when nothing listens on a local port in time" {
  sleep 30 &
  local pid=$!
  run wait_for_local_port "$pid" 1 1
  kill "$pid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing listens on local port 1 after 1s"* ]]
}

@test "lists the cluster's own suite, then each deployed package's suite" {
  run cluster_suites
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = "$root_directory/clusters/singularity/tests/cluster" ]
  [ "${lines[1]}" = "$root_directory/packages/cilium/tests/cluster" ]
  [ "${lines[2]}" = "$root_directory/packages/flux/tests/cluster" ]
  [ "${lines[3]}" = "$root_directory/packages/cert-manager/tests/cluster" ]
  [ "${lines[4]}" = "$root_directory/packages/openbao/tests/cluster" ]
  [ "${lines[5]}" = "$root_directory/packages/cv/tests/cluster" ]
  [ "${lines[6]}" = "$root_directory/packages/kyverno/tests/cluster" ]
}

@test "lists only the cluster's own suite when it has no Flux build" {
  MISE_PROJECT_ROOT=$(make_repository environments/bare/environment.yaml clusters/singularity/tests/cluster/chainsaw-test.yaml)
  MISE_ENV=bare run cluster_suites
  [ "$status" -eq 0 ]
  [ "$output" = "$MISE_PROJECT_ROOT/clusters/singularity/tests/cluster" ]
}

@test "skips a deployed package without a suite and a package the environment does not deploy" {
  MISE_PROJECT_ROOT=$(make_repository environments/x/environment.yaml clusters/singularity/payload/kustomization.yaml \
    packages/tested/tests/cluster/chainsaw-test.yaml packages/untested/kustomization.yaml \
    packages/undeployed/tests/cluster/chainsaw-test.yaml)
  printf 'resources:\n  - ../../../packages/untested\n  - ../../../packages/tested\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  MISE_ENV=x run cluster_suites
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$MISE_PROJECT_ROOT/packages/tested/tests/cluster" ]
}

@test "keeps only the chosen packages' suites, and always the cluster's own" {
  run cluster_suites flux
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$root_directory/clusters/singularity/tests/cluster" ]
  [ "${lines[1]}" = "$root_directory/packages/flux/tests/cluster" ]
}

@test "refuses a package the environment does not deploy, naming the ones it does" {
  run cluster_suites cilium,ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown package 'ghost' for environment 'local'; choose from: cilium flux cert-manager openbao cv kyverno"* ]]
}

@test "names an env:e2e step after the task it runs, or its first word" {
  [ "$(step_label mise run --yes env:destroy local)" = env:destroy ]
  [ "$(step_label env -u MISE_PROJECT_ROOT FIRMAMENT_GIT_BRANCH=main mise --cd /w run env:apply local)" = env:apply ]
  [ "$(step_label platform_versions)" = platform_versions ]
}

@test "reports each step's time and its change since the earlier run" {
  printf 'env:destroy\t30\nenv:apply\t379\n' >"$BATS_TEST_TMPDIR/before"
  printf 'env:destroy\t28\nenv:apply\t420\nverify\t416\n' >"$BATS_TEST_TMPDIR/now"
  run step_time_report "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/now"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^\ +env:destroy\ +28\ s\ +\(-2\ s\)$ ]]
  [[ "${lines[1]}" =~ ^\ +env:apply\ +420\ s\ +\(\+41\ s\)$ ]]
  [[ "${lines[2]}" =~ ^\ +verify\ +416\ s\ +\(new\)$ ]]
  [[ "${lines[3]}" =~ ^\ +total\ +864\ s$ ]]
}

@test "marks every step new when there is no earlier run" {
  printf 'env:apply\t379\n' >"$BATS_TEST_TMPDIR/now"
  run step_time_report "$BATS_TEST_TMPDIR/missing" "$BATS_TEST_TMPDIR/now"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"379 s  (new)" ]]
}

# A repository on main, pushed to origin, whose environment x runs a cluster that deploys
# cilium and flux but not policy-kyverno, then a branch off it.
branch_repository() {
  MISE_PROJECT_ROOT=$(make_pushed_repository main environments/x/environment.yaml clusters/singularity/payload/kustomization.yaml tofu/roots/r/main.tf \
    packages/cilium/values.yaml packages/flux/fluxinstance.yaml packages/policy-kyverno/policy.yaml README.md)
  printf 'resources:\n  - ../../../packages/cilium\n  - ../../../packages/flux\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  commit_and_push "$MISE_PROJECT_ROOT" main packages
  git -C "$MISE_PROJECT_ROOT" switch -q -c feature
}

@test "changed packages: a package change selects its package" {
  branch_repository
  printf 'x\n' >>"$MISE_PROJECT_ROOT/packages/cilium/values.yaml"
  MISE_ENV=x run changed_packages
  [ "$status" -eq 0 ]
  [ "$output" = cilium ]
}

@test "changed packages: committed and untracked changes to two packages select both, once each" {
  branch_repository
  printf 'x\n' >>"$MISE_PROJECT_ROOT/packages/flux/fluxinstance.yaml"
  git -C "$MISE_PROJECT_ROOT" -c user.name=t -c user.email=t@example.test commit -qam flux
  mkdir -p "$MISE_PROJECT_ROOT/packages/cilium/tests"
  : >"$MISE_PROJECT_ROOT/packages/cilium/tests/cluster"
  printf 'y\n' >>"$MISE_PROJECT_ROOT/packages/flux/fluxinstance.yaml"
  MISE_ENV=x run changed_packages
  [ "$status" -eq 0 ]
  [ "$output" = flux,cilium ]
}

@test "changed packages: Markdown and packages the environment does not deploy select none" {
  branch_repository
  printf 'x\n' >>"$MISE_PROJECT_ROOT/README.md"
  printf 'x\n' >>"$MISE_PROJECT_ROOT/packages/policy-kyverno/policy.yaml"
  MISE_ENV=x run changed_packages
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "changed packages: a change outside packages selects every package" {
  branch_repository
  printf 'x\n' >>"$MISE_PROJECT_ROOT/packages/cilium/values.yaml"
  printf 'x\n' >>"$MISE_PROJECT_ROOT/tofu/roots/r/main.tf"
  MISE_ENV=x run changed_packages
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "changed packages: fails without origin/main" {
  MISE_PROJECT_ROOT=$(make_repository environments/x/environment.yaml)
  git -C "$MISE_PROJECT_ROOT" init -q
  MISE_ENV=x run changed_packages
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot find where this branch left origin/main; fetch origin first"* ]]
}

@test "package selection refuses --only together with --changed" {
  run package_selection cilium true
  [ "$status" -ne 0 ]
  [[ "$output" == *"--only and --changed cannot be combined"* ]]
}

@test "package selection passes --only on, and selects every package without flags" {
  [ "$(package_selection flux false)" = flux ]
  [ -z "$(package_selection "" false)" ]
}

@test "none selects no package and passes the package check" {
  run check_packages none
  [ "$status" -eq 0 ]
  ! package_selected cilium none
  run cluster_suites none
  [ "$output" = "$root_directory/clusters/singularity/tests/cluster" ]
}

@test "counts only directories the Flux build lists as packages" {
  MISE_PROJECT_ROOT=$(make_repository environments/x/environment.yaml clusters/singularity/payload/kustomization.yaml clusters/singularity/payload/namespace.yaml \
    packages/cilium/kustomization.yaml)
  printf 'resources:\n  - namespace.yaml\n  - ../../../packages/cilium\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  MISE_ENV=x run deployed_packages
  [ "$status" -eq 0 ]
  [ "$output" = "$MISE_PROJECT_ROOT/packages/cilium" ]
}

@test "counts a package the cluster binds although its Flux build does not list it" {
  MISE_PROJECT_ROOT=$(make_repository environments/x/environment.yaml clusters/singularity/payload/kustomization.yaml clusters/singularity/packages.yaml \
    packages/cilium/kustomization.yaml packages/rendered/tests/cluster/chainsaw-test.yaml)
  printf 'resources:\n  - ../../../packages/cilium\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  printf -- '- package: cilium\n  namespace: kube-system\n  tenant: platform\n- package: rendered\n  namespace: rendered\n  tenant: platform\n- package: nodir\n  namespace: nodir\n  tenant: platform\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  MISE_ENV=x run deployed_packages
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$MISE_PROJECT_ROOT/packages/cilium" ]
  [ "${lines[1]}" = "$MISE_PROJECT_ROOT/packages/rendered" ]
}

@test "fails when the cluster's Flux build cannot be read" {
  MISE_PROJECT_ROOT=$(make_repository environments/x/environment.yaml clusters/singularity/payload/kustomization.yaml)
  printf 'resources: [\n' >"$MISE_PROJECT_ROOT/clusters/singularity/payload/kustomization.yaml"
  MISE_ENV=x run cluster_suites
  [ "$status" -ne 0 ]
}

@test "accepts a local port nothing listens on" {
  run require_free_local_port 1
  [ "$status" -eq 0 ]
}

@test "refuses a local port something already listens on" {
  local port=$((20000 + RANDOM % 20000))
  # -k keeps listening after the connection the check opens.
  nc -lk 127.0.0.1 "$port" >/dev/null &
  local listener=$!
  wait_for_local_port "$listener" "$port" 5
  run require_free_local_port "$port"
  kill "$listener"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local port $port is already in use; pick another with --port"* ]]
}

# Runs a script with the variables git exports to a hook in the caller
# repository, as a linked worktree's hook sees them. The script sources the
# given file, runs the given command, then commits in a fresh repository of
# its own. Prints the caller's and the scratch repository's commits.
commit_as_if_from_hook() {
  local source_file="$1" command="$2"
  local caller="$BATS_TEST_TMPDIR/caller" scratch="$BATS_TEST_TMPDIR/scratch"
  git init -q -b main "$caller"
  mkdir -p "$scratch"
  GIT_DIR="$caller/.git" GIT_WORK_TREE="$caller" GIT_INDEX_FILE="$caller/.git/index" \
    bash -c 'source "$1"; $2; cd "$3" && git init -q -b main && git -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m scratch' \
    _ "$source_file" "$command" "$scratch"
  printf 'caller: %s\n' "$(git -C "$caller" log --format=%s 2>/dev/null)"
  printf 'scratch: %s\n' "$(git -C "$scratch" log --format=%s 2>/dev/null)"
}

@test "a task started from a hook commits in its own repository, not the caller's" {
  run commit_as_if_from_hook "$root_directory/.mise/lib.sh" true
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "caller: " ]
  [ "${lines[1]}" = "scratch: scratch" ]
}

@test "a test run from a hook commits in its own repository, not the caller's" {
  run commit_as_if_from_hook "$root_directory/.mise/tests/stubs.bash" seal_git
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "caller: " ]
  [ "${lines[1]}" = "scratch: scratch" ]
}

@test "tests cannot reach a remote over the network" {
  run git ls-remote https://github.com/cilium/cilium.git
  [ "$status" -ne 0 ]
  [[ "$output" == *"transport 'https' not allowed"* ]]
}

owner_file() {
  printf '%s/environments/local/owner\n' "$FIRMAMENT_STATE_HOME"
}

# Records another worktree, which exists, as the owner of the local environment.
owned_by_other_worktree() {
  mkdir -p "$BATS_TEST_TMPDIR/other-worktree" "$(dirname -- "$(owner_file)")"
  printf '%s\n' "$BATS_TEST_TMPDIR/other-worktree" >"$(owner_file)"
}

@test "records the checkout that claims an environment as its owner" {
  run claim_environment
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "refuses an environment another existing worktree owns" {
  owned_by_other_worktree
  run claim_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' belongs to the worktree $BATS_TEST_TMPDIR/other-worktree"*"FIRMAMENT_TAKE_OVER=1"* ]]
  [ "$(cat "$(owner_file)")" = "$BATS_TEST_TMPDIR/other-worktree" ]
}

@test "claims an environment whose owning worktree no longer exists" {
  owned_by_other_worktree
  rmdir "$BATS_TEST_TMPDIR/other-worktree"
  run claim_environment
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "takes over another worktree's environment when asked" {
  owned_by_other_worktree
  FIRMAMENT_TAKE_OVER=1 run claim_environment
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "counts the steps of a run as the checkout that started it" {
  owned_by_other_worktree
  FIRMAMENT_WORKTREE="$BATS_TEST_TMPDIR/other-worktree" run claim_environment
  [ "$status" -eq 0 ]
}

@test "forgets the owner of a destroyed environment" {
  claim_environment
  release_environment
  [ ! -e "$(owner_file)" ]
}

teardown() {
  end_background_processes
}

runs_directory() {
  printf '%s/runs\n' "$TF_VAR_state_directory"
}

@test "records the claiming run in the state directory" {
  claim_environment
  local files=("$(runs_directory)"/*)
  [ "${#files[@]}" -eq 1 ]
  [[ "${files[0]##*/}" == "$$."* ]]
}

@test "claims again from the same process without refusing itself" {
  claim_environment
  claim_environment
  local files=("$(runs_directory)"/*)
  [ "${#files[@]}" -eq 1 ]
}

@test "refuses while another run is alive, names it, and records nothing" {
  local pid
  pid=$(start_background_process)
  write_run "$(run_name_of "$pid")"
  run claim_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' is busy: env:apply (pid $pid) from /checkout/elsewhere since 2026-10-15 12:31:00"* ]]
  [[ "$output" == *"kill $pid (processes it left behind: pkill -g "* ]]
  [[ "$output" == *"remove $(runs_directory)/$(run_name_of "$pid")"* ]]
  [ ! -e "$(owner_file)" ]
  local files=("$(runs_directory)"/*)
  [ "${#files[@]}" -eq 1 ]
}

@test "does not count a run whose process ended, and forgets its file" {
  local pid
  pid=$(ended_process_pid)
  write_run "$pid.$pid.Thu_Oct_15_12_31_00_2026"
  run claim_environment
  [ "$status" -eq 0 ]
  [ ! -e "$(runs_directory)/$pid.$pid.Thu_Oct_15_12_31_00_2026" ]
}

@test "does not trust a reused pid: a live process started at another time, with no group left" {
  local pid dead
  pid=$(start_background_process)
  dead=$(ended_process_pid)
  write_run "$pid.$dead.Thu_Oct_15_12_31_00_2026"
  run claim_environment
  [ "$status" -eq 0 ]
}

@test "forgets a file in the runs directory that is not a run" {
  mkdir -p "$(runs_directory)"
  : >"$(runs_directory)/notes.txt"
  run claim_environment
  [ "$status" -eq 0 ]
  [ ! -e "$(runs_directory)/notes.txt" ]
}

@test "does not count the ancestors of a run" {
  local pid name
  pid=$(start_background_process)
  name=$(run_name_of "$pid")
  write_run "$name"
  FIRMAMENT_RUN_ANCESTORS="other:$name" run claim_environment
  [ "$status" -eq 0 ]
}

@test "holds while a process of a killed run's group still runs, and frees when the group ends" {
  local leader name
  set -m
  bash -c 'sleep 60 & wait' 3>&- &
  leader=$!
  set +m
  remember_process "$leader"
  until [ -n "$(pgrep -P "$leader")" ]; do sleep 0.05; done
  name=$(run_name_of "$leader")
  write_run "$name"
  kill -9 "$leader"
  while kill -0 "$leader" 2>/dev/null; do sleep 0.05; done
  run claim_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"pkill -g $leader"* ]]
  pkill -g "$leader"
  while pgrep -g "$leader" >/dev/null; do sleep 0.05; done
  run claim_environment
  [ "$status" -eq 0 ]
}

@test "does not hold through a group the ended run only belonged to" {
  local pid dead
  pid=$(start_background_process)
  dead=$(ended_process_pid)
  write_run "$dead.$pid.Thu_Oct_15_12_31_00_2026"
  run claim_environment
  [ "$status" -eq 0 ]
}

@test "keeps the lock for a nested run after the run that started it ends" {
  local parent name child_marker
  parent=$(start_background_process)
  name=$(run_name_of "$parent")
  write_run "$name"
  FIRMAMENT_RUN_ANCESTORS="$name" bash -c 'source "$1/.mise/lib.sh"; claim_environment; sleep 60' _ "$root_directory" >/dev/null 2>&1 3>&- &
  remember_process "$!"
  until [ "$(find "$(runs_directory)" -type f | wc -l)" -ge 2 ]; do sleep 0.05; done
  kill "$parent"
  while kill -0 "$parent" 2>/dev/null; do sleep 0.05; done
  run claim_environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"is busy"* ]]
}

@test "stops when it cannot record that a run is alive" {
  mkdir -p "$TF_VAR_state_directory"
  chmod 500 "$TF_VAR_state_directory"
  run claim_environment
  chmod 700 "$TF_VAR_state_directory"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot create $(runs_directory)"* ]]
}

@test "never lets two runs that start close together both proceed" {
  export TF_VAR_state_directory MISE_PROJECT_ROOT
  local results="$BATS_TEST_TMPDIR/results" round
  : >"$results"
  for round in 1 2 3 4 5 6 7 8 9 10; do
    for _ in 1 2; do
      bash -c '
        source "$1/.mise/lib.sh"
        if claim_environment 2>/dev/null; then
          if mkdir "$2/inside" 2>/dev/null; then sleep 0.1; rmdir "$2/inside"; echo proceeded >>"$3"
          else echo overlapped >>"$3"; fi
        fi' _ "$root_directory" "$TF_VAR_state_directory" "$results" 3>&- &
      sleep 0.03
    done
    wait
  done
  ! grep -q overlapped "$results"
  grep -q proceeded "$results"
}
