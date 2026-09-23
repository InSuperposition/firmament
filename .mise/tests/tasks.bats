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
    apply.sh | destroy.sh) continue ;;
    esac
    rm -f "$CALLS"
    run_task "$script" local
    [ "$status" -eq 0 ] || fail "$script: $output"
    ! grep -Eq '^tofu .* (apply|destroy)( |$)' "$CALLS" || fail "$script changed infrastructure: $(cat "$CALLS")"
  done
}

@test "destroy tasks ask for confirmation" {
  local script
  for script in "$root_directory"/.mise/tasks/*/destroy.sh; do
    grep -q '^#MISE confirm="' "$script" || fail "$script destroys without confirmation"
  done
}

@test "apply tasks wait for the cluster only after applying" {
  run_task "$root_directory/.mise/tasks/k0s/apply.sh" local
  [ "$status" -eq 0 ]
  run grep -nE '^(tofu .* apply |cilium )' "$CALLS"
  [[ "${lines[0]}" == *"apply -input=false -auto-approve"* ]]
  [[ "${lines[1]}" == *"cilium --kubeconfig /state/admin.kubeconfig status"* ]]
}

@test "verify runs every *:verify task, one at a time, against the environment" {
  run_task "$root_directory/.mise/tasks/verify.sh" local
  [ "$status" -eq 0 ]
  run grep '^mise run' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%% |*}" = "mise run a:verify local" ]
  [ "${lines[1]%% |*}" = "mise run k0s:verify local" ]
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
