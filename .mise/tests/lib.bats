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
  FIRMAMENT_GIT_BRANCH='main;touch x' run tofu_in_environment local plan
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
}

@test "prints the revision Flux reports for origin's branch tip" {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environment/local/main.tf)
  run flux_revision feature/test
  [ "$status" -eq 0 ]
  [ "$output" = "refs/heads/feature/test@sha1:$(git -C "$MISE_PROJECT_ROOT" rev-parse HEAD)" ]
}

@test "fails for a branch that origin does not have" {
  MISE_PROJECT_ROOT=$(make_pushed_repository feature/test environment/local/main.tf)
  run flux_revision feature/other
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/feature/other does not exist; push the branch first"* ]]
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

@test "counts the cilium release current when it runs the ConfigMap's values in any key order" {
  CILIUM_VALUES=$'# Chart values.\nb:\n  d: 2\n  c: 1\na: "1.20"' \
    RELEASE_VALUES=$'a: "1.20"\nb:\n  c: 1\n  d: 2' \
    run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -eq 0 ]
}

@test "waits while the cilium release runs other values than the ConfigMap" {
  CILIUM_VALUES='a: 2' RELEASE_VALUES='a: 1' run wait_for_cilium_values /kubeconfig 0 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"the cilium release does not run the values in the cilium-values ConfigMap after 0s"* ]]
}

@test "never counts an empty cilium-values ConfigMap as deployed" {
  CILIUM_VALUES='' RELEASE_VALUES='' run cilium_values_deployed /kubeconfig
  [ "$status" -ne 0 ]
}

@test "fails for an output the state has no value for, instead of printing nothing" {
  NO_OUTPUTS=1 run environment_output local kubeconfig_path
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' has no kubeconfig_path in its state; apply it first"* ]]
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

@test "lists the environment's own suite, then each deployed component's suite" {
  run cluster_suites local
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$root_directory/environment/local/tests/cluster" ]
  [ "${lines[1]}" = "$root_directory/components/cni-cilium/tests/cluster" ]
  [ "${lines[2]}" = "$root_directory/components/gitops-flux/tests/cluster" ]
}

@test "lists only the environment's own suite when it has no Flux build" {
  MISE_PROJECT_ROOT=$(make_repository environment/bare/tests/cluster/chainsaw-test.yaml)
  run cluster_suites bare
  [ "$status" -eq 0 ]
  [ "$output" = "$MISE_PROJECT_ROOT/environment/bare/tests/cluster" ]
}

@test "skips a deployed component without a suite and a component the environment does not deploy" {
  MISE_PROJECT_ROOT=$(make_repository environment/x/flux/kustomization.yaml \
    components/tested/tests/cluster/chainsaw-test.yaml components/untested/kustomization.yaml \
    components/undeployed/tests/cluster/chainsaw-test.yaml)
  printf 'resources:\n  - ../../../components/untested\n  - ../../../components/tested\n' \
    >"$MISE_PROJECT_ROOT/environment/x/flux/kustomization.yaml"
  run cluster_suites x
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$MISE_PROJECT_ROOT/components/tested/tests/cluster" ]
}

@test "keeps only the chosen modules' suites, and always the environment's own" {
  run cluster_suites local flux
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$root_directory/environment/local/tests/cluster" ]
  [ "${lines[1]}" = "$root_directory/components/gitops-flux/tests/cluster" ]
}

@test "refuses a module the environment does not deploy, naming the ones it does" {
  run cluster_suites local cilium,cni-cilium
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown module 'cni-cilium' for environment 'local'; choose from: cilium flux"* ]]
}

@test "lists the conformance tests the chosen modules need" {
  run conformance_patterns local cilium
  [ "$status" -eq 0 ]
  [ "$output" = ".*" ]
  run conformance_patterns local flux
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reads conformance tests without comments or blank lines, from every module when none is chosen" {
  MISE_PROJECT_ROOT=$(make_repository environment/x/flux/kustomization.yaml \
    components/net-a/tests/conformance components/net-b/tests/conformance)
  printf 'resources:\n  - ../../../components/net-a\n  - ../../../components/net-b\n' \
    >"$MISE_PROJECT_ROOT/environment/x/flux/kustomization.yaml"
  printf '# policy tests\n\nclient-egress\n  # indented comment\n' >"$MISE_PROJECT_ROOT/components/net-a/tests/conformance"
  printf 'to-fqdns\n' >"$MISE_PROJECT_ROOT/components/net-b/tests/conformance"
  run conformance_patterns x
  [ "$status" -eq 0 ]
  [ "$output" = $'client-egress\nto-fqdns' ]
}

@test "refuses conformance tests for a module the environment does not deploy" {
  run conformance_patterns local nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown module 'nope'"* ]]
}

@test "names a component's module after its folder without the role prefix" {
  [ "$(module_name /x/components/cni-cilium)" = cilium ]
  [ "$(module_name components/gitops-flux)" = flux ]
  [ "$(module_name components/policy-kyverno-audit)" = kyverno-audit ]
}

@test "counts only directories the Flux build lists as components" {
  MISE_PROJECT_ROOT=$(make_repository environment/x/flux/kustomization.yaml environment/x/flux/namespace.yaml \
    components/cni-cilium/kustomization.yaml)
  printf 'resources:\n  - namespace.yaml\n  - ../../../components/cni-cilium\n' \
    >"$MISE_PROJECT_ROOT/environment/x/flux/kustomization.yaml"
  run deployed_components x
  [ "$status" -eq 0 ]
  [ "$output" = "$MISE_PROJECT_ROOT/components/cni-cilium" ]
}

@test "fails when the environment's Flux build cannot be read" {
  MISE_PROJECT_ROOT=$(make_repository environment/x/flux/kustomization.yaml)
  printf 'resources: [\n' >"$MISE_PROJECT_ROOT/environment/x/flux/kustomization.yaml"
  run cluster_suites x
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
  printf '%s/environment/local/owner\n' "$FIRMAMENT_STATE_HOME"
}

# Records another worktree, which exists, as the owner of the local environment.
owned_by_other_worktree() {
  mkdir -p "$BATS_TEST_TMPDIR/other-worktree" "$(dirname -- "$(owner_file)")"
  printf '%s\n' "$BATS_TEST_TMPDIR/other-worktree" >"$(owner_file)"
}

@test "records the checkout that claims an environment as its owner" {
  run claim_environment local
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "refuses an environment another existing worktree owns" {
  owned_by_other_worktree
  run claim_environment local
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment 'local' belongs to the worktree $BATS_TEST_TMPDIR/other-worktree"*"FIRMAMENT_TAKE_OVER=1"* ]]
  [ "$(cat "$(owner_file)")" = "$BATS_TEST_TMPDIR/other-worktree" ]
}

@test "claims an environment whose owning worktree no longer exists" {
  owned_by_other_worktree
  rmdir "$BATS_TEST_TMPDIR/other-worktree"
  run claim_environment local
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "takes over another worktree's environment when asked" {
  owned_by_other_worktree
  FIRMAMENT_TAKE_OVER=1 run claim_environment local
  [ "$status" -eq 0 ]
  [ "$(cat "$(owner_file)")" = "$MISE_PROJECT_ROOT" ]
}

@test "counts the steps of a run as the checkout that started it" {
  owned_by_other_worktree
  FIRMAMENT_WORKTREE="$BATS_TEST_TMPDIR/other-worktree" run claim_environment local
  [ "$status" -eq 0 ]
}

@test "forgets the owner of a destroyed environment" {
  claim_environment local
  release_environment local
  [ ! -e "$(owner_file)" ]
}
