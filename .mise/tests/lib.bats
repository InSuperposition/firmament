#!/usr/bin/env bats

setup() {
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  export MISE_PROJECT_ROOT="$root_directory"
  export FIRMAMENT_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  stubs="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubs"
  for tool in tofu cilium kubectl; do
    stub "$tool"
  done
  PATH="$stubs:$PATH"
  # shellcheck source=../lib.sh
  source "$root_directory/.mise/lib.sh"
}

# Replaces a tool with a script that records its arguments and the
# TF_VAR_* variables it received.
stub() {
  cat >"$stubs/$1" <<EOF
#!/usr/bin/env bash
printf '%s %s | state=%s key=%s\n' "$1" "\$*" "\${TF_VAR_state_directory:-}" "\${TF_VAR_orbstack_ssh_key_path:-}" >>"\$CALLS"
[[ "\$*" == *"output -raw kubeconfig_path"* ]] && printf '/state/admin.kubeconfig'
exit 0
EOF
  chmod +x "$stubs/$1"
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

@test "runs tofu in the environment root with the machine-side variables" {
  FIRMAMENT_ORBSTACK_SSH_KEY=/keys/id tofu_in_environment local plan -input=false
  run cat "$CALLS"
  [ "$output" = "tofu -chdir=$root_directory/environment/local plan -input=false | state=$FIRMAMENT_STATE_HOME/environment/local key=/keys/id" ]
}

@test "defaults the SSH key to OrbStack's" {
  unset FIRMAMENT_ORBSTACK_SSH_KEY
  tofu_in_environment local plan
  run cat "$CALLS"
  [[ "$output" == *"key=$HOME/.orbstack/ssh/id_ed25519" ]]
}

@test "points the backend at the environment's state file" {
  init_environment local
  [ -d "$FIRMAMENT_STATE_HOME/environment/local" ]
  run cat "$CALLS"
  [[ "$output" == *"init -input=false -reconfigure -backend-config=path=$FIRMAMENT_STATE_HOME/environment/local/terraform.tfstate"* ]]
}

@test "waits for Cilium before the nodes, using the kubeconfig from state" {
  wait_for_cluster local
  run grep -v '^tofu ' "$CALLS"
  [ "${lines[0]%% |*}" = "cilium --kubeconfig /state/admin.kubeconfig status --wait --wait-duration=10m --interactive=false" ]
  [ "${lines[1]%% |*}" = "kubectl --kubeconfig /state/admin.kubeconfig wait --for=condition=Ready node --all --timeout=5m" ]
}

@test "stops before tofu when the environment does not exist" {
  run tofu_in_environment nowhere plan
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
}

@test "treats an empty XDG_STATE_HOME as unset" {
  run env -u FIRMAMENT_STATE_HOME XDG_STATE_HOME= mise env --json -C "$root_directory"
  [ "$status" -eq 0 ]
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = "$HOME/.local/state/firmament" ]
}

@test "honors a FIRMAMENT_STATE_HOME set by the caller" {
  run env FIRMAMENT_STATE_HOME=/custom mise env --json -C "$root_directory"
  [ "$(jq -r .FIRMAMENT_STATE_HOME <<<"$output")" = /custom ]
}

@test "points KUBECONFIG at the local cluster from the root and inside environment/local" {
  root=$(env -u KUBECONFIG mise env --json -C "$root_directory" | jq -r .KUBECONFIG)
  local_environment=$(env -u KUBECONFIG mise env --json -C "$root_directory/environment/local" | jq -r .KUBECONFIG)
  [ "$root" = "$FIRMAMENT_STATE_HOME/environment/local/admin.kubeconfig" ]
  [ "$local_environment" = "$root" ]
}
