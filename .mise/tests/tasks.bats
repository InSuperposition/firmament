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
run_task() {
  local script="$1" environment="$2"
  usage_environment="$environment" run "$script"
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
  for script in $(environment_scripts); do
    case "$(basename "$script")" in
    # e2e.sh destroys through `mise run`; its own tests check what it runs.
    apply.sh | destroy.sh | e2e.sh) continue ;;
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

@test "env:destroy forgets the Flux bootstrap before destroying the rest" {
  STATE_LIST=$'module.bootstrap_flux.helm_release.this\nmodule.vm_orb.orbstack_machine.this' run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  run grep -E '^tofu .* (state rm|destroy) ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *" state rm -backup=$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate.bootstrap.backup module.bootstrap_flux "* ]]
  [[ "${lines[1]}" == *" destroy -input=false -auto-approve "* ]]
}

@test "env:destroy destroys without touching state when there is no bootstrap" {
  STATE_LIST=module.vm_orb.orbstack_machine.this run_task "$root_directory/.mise/tasks/env/destroy.sh" local
  [ "$status" -eq 0 ]
  ! grep -q ' state rm ' "$CALLS"
  grep -q ' destroy -input=false -auto-approve ' "$CALLS"
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

@test "verify runs every *:verify task, one at a time, against the environment" {
  run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "mise run a:verify local" ]
  [ "${lines[1]%% |*}" = "mise run k0s:verify local" ]
}

@test "tofu:test initializes and tests each suite directory, and never applies" {
  MISE_PROJECT_ROOT=$(make_repository modules/a/tests/unit.tftest.hcl environment/e/tests/wiring.tftest.hcl)
  run "$root_directory/.mise/tasks/tofu/test.sh"
  [ "$status" -eq 0 ]
  run cut -d"|" -f1 "$CALLS"
  [ "${lines[0]}" = "tofu -chdir=$MISE_PROJECT_ROOT/environment/e init -backend=false -input=false -reconfigure " ]
  [ "${lines[1]}" = "tofu -chdir=$MISE_PROJECT_ROOT/environment/e test " ]
  [ "${lines[2]}" = "tofu -chdir=$MISE_PROJECT_ROOT/modules/a init -backend=false -input=false -reconfigure " ]
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

@test "cilium:conformance removes its test workloads after a passing suite" {
  run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -eq 0 ]
  run grep '^cilium ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --log-check-only-test-time" ]
  [ "${lines[1]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig connectivity test --cleanup" ]
}

@test "cilium:conformance keeps the test workloads of a failing suite" {
  printf '#!/usr/bin/env bash\nprintf "cilium %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *--log-check-only-test-time* ]]\n' >"$stubs/cilium"
  run_task "$root_directory/.mise/tasks/cilium/conformance.sh" local
  [ "$status" -ne 0 ]
  ! grep -q -- --cleanup "$CALLS"
}

# Replaces the mise stub with one that records each call and fails the call
# whose arguments equal $FAIL_CALL.
e2e_mise_stub() {
  cat >"$stubs/mise" <<'STUB'
#!/usr/bin/env bash
printf 'mise %s\n' "$*" >>"$CALLS"
[[ "$*" != "${FAIL_CALL:-}" ]]
STUB
  chmod +x "$stubs/mise"
}

@test "env:e2e rebuilds the cluster from scratch, runs every live check, and destroys it" {
  e2e_mise_stub
  run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -eq 0 ]
  [[ "$output" == *"env:e2e passed for local; the cluster is destroyed."* ]]
  run grep '^mise ' "$CALLS"
  [ "$output" = "mise run --yes env:destroy local
mise run env:apply local
mise run verify local
mise run cilium:conformance local
mise run --yes env:destroy local" ]
}

@test "env:e2e stops at the first failing step and leaves the cluster for inspection" {
  e2e_mise_stub
  FAIL_CALL="run verify local" run_task "$root_directory/.mise/tasks/env/e2e.sh" local
  [ "$status" -ne 0 ]
  [[ "$output" == *"env:e2e stopped at: mise run verify local"* ]]
  [[ "$output" == *"Remove it with: mise run --yes env:destroy local"* ]]
  [ "$(tail -1 "$CALLS")" = "mise run verify local" ]
  [ "$(grep -c '^mise ' "$CALLS")" -eq 3 ]
}

# Replaces the chainsaw stub with one that also records KUBECONFIG.
record_chainsaw_kubeconfig() {
  printf '#!/usr/bin/env bash\nprintf "chainsaw %%s | KUBECONFIG=%%s\\n" "$*" "$KUBECONFIG" >>"$CALLS"\n' >"$stubs/chainsaw"
}

@test "env:verify runs the cluster suite against the environment's kubeconfig" {
  record_chainsaw_kubeconfig
  run_task "$root_directory/.mise/tasks/env/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^chainsaw ' "$CALLS"
  [ "$output" = "chainsaw test --test-dir $root_directory/environment/local/tests/cluster | KUBECONFIG=/state/admin.kubeconfig" ]
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
