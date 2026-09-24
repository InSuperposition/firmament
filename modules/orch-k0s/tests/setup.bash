setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/k0s"
  export FIRMAMENT_K0S_SSH_ADDRESS=127.0.0.1
  export FIRMAMENT_K0S_SSH_USER='developer@firmament'
  export FIRMAMENT_K0S_SSH_PORT=32222
  export FIRMAMENT_K0S_SSH_KEY=/tmp/orbstack-test-key
  export FIRMAMENT_K0S_API_ADDRESS=firmament.orb.local
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  k0s_directory="$root_directory/modules/orch-k0s"

  tofu -chdir="$k0s_directory" init -backend=false -input=false -reconfigure >/dev/null
}
