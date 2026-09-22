setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/k0s"
  export FIRMAMENT_K0S_SSH_ADDRESS=127.0.0.1
  export FIRMAMENT_K0S_SSH_USER='developer@firmament'
  export FIRMAMENT_K0S_SSH_PORT=32222
  export FIRMAMENT_K0S_SSH_KEY=/tmp/orbstack-test-key
  export FIRMAMENT_K0S_API_ADDRESS=firmament.orb.local
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  k0s_directory="$root_directory/bootstrap/k0s"

  tofu -chdir="$k0s_directory" init -input=false -reconfigure \
    -backend-config="path=$BATS_TEST_ROOT/terraform.tfstate" >/dev/null
}

plan_json() {
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$k0s_directory" plan -input=false -out="$plan" \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var="state_directory=$BATS_TEST_ROOT" >/dev/null
  tofu -chdir="$k0s_directory" show -json "$plan"
}
