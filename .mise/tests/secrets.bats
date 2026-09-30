#!/usr/bin/env bats

load stubs.bash

# Each test runs the repository's betterleaks step from hk.pkl in a small
# repository that holds a copy of hk.pkl and the files a test plants. The
# private key is generated when the test runs, so no secret is committed.
setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  mkdir -p "$repository"
  cp "$root_directory/hk.pkl" "$repository/"
  printf 'no secret here\n' >"$repository/README.md"
  git -C "$repository" init -q
}

scan() {
  git -C "$repository" add -A
  run bash -c 'cd "$1" && hk check --all --step betterleaks' _ "$repository"
}

@test "betterleaks passes a repository without secrets" {
  scan
  [ "$status" -eq 0 ]
}

@test "betterleaks fails on a private key in a tracked file and names the file" {
  mkdir -p "$repository/packages/net-sample/tests"
  ssh-keygen -q -t ed25519 -N '' -C '' -f "$BATS_TEST_TMPDIR/key"
  cp "$BATS_TEST_TMPDIR/key" "$repository/packages/net-sample/tests/fixture"
  scan
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/net-sample/tests/fixture"* ]]
  [[ "$output" == *"private-key"* ]]
}
