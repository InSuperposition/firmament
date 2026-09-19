setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/ubuntu"
  export FIRMAMENT_SSH_TARGET=fixture
  export PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  mkdir -p "$BATS_TEST_ROOT"
  script="$BATS_TEST_DIRNAME/../scripts/bootstrap:ubuntu.sh"
}
