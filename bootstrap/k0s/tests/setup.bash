setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/k0s"
  export FIRMAMENT_K0S_SSH_ADDRESS=127.0.0.1
  export FIRMAMENT_K0S_SSH_USER='developer@firmament'
  export FIRMAMENT_K0S_SSH_PORT=32222
  export FIRMAMENT_K0S_SSH_KEY=/tmp/orbstack-test-key
  export FIRMAMENT_K0S_API_ADDRESS=firmament.orb.local
  export FIRMAMENT_K0S_STATE_DIRECTORY="$BATS_TEST_ROOT/state"
  export PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  mkdir -p "$BATS_TEST_ROOT"
  script="$BATS_TEST_DIRNAME/../scripts/bootstrap:k0s.sh"
}

rendered_config() {
  printf '%s/k0sctl.rendered.yaml\n' "$FIRMAMENT_K0S_STATE_DIRECTORY"
}
