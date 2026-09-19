setup() {
  export ORB_TEST_ROOT="$BATS_TEST_TMPDIR/orb"
  export ORB_TEST_FIXTURE="$BATS_TEST_DIRNAME/fixtures/machine.json"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state with spaces"
  export PATH="$BATS_TEST_DIRNAME/fixtures:$PATH"
  mkdir -p "$ORB_TEST_ROOT"
  bootstrap="$BATS_TEST_DIRNAME/../scripts/bootstrap:orb.sh"
  adopt="$BATS_TEST_DIRNAME/../scripts/orb:adopt.sh"
  marker="$XDG_STATE_HOME/firmament/targets/firmament/orb/ownership.json"
}

existing_machine() {
  cp "$ORB_TEST_FIXTURE" "$ORB_TEST_ROOT/machine.json"
}

owned_machine() {
  existing_machine
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' '{"machine_id":"01M2WX3M540GRA73ECJ873RWCA"}' >"$marker"
}
