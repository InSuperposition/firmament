#!/usr/bin/env bats

# mise run evidence on a stand-in repository, so a test never reads the real
# checkout.

bats_require_minimum_version 1.5.0

load stubs.bash

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  mkdir -p "$repository/.mise/tasks" "$repository/contracts/run-record" "$BATS_TEST_TMPDIR/state/evidence"
  cp "$root_directory/.mise/lib.sh" "$repository/.mise/"
  cp "$root_directory/.mise/tasks/evidence.sh" "$repository/.mise/tasks/"
  cp "$root_directory/contracts/run-record/schema.cue" "$repository/contracts/run-record/"
  record="$BATS_TEST_TMPDIR/record.json"
  snapshot="$BATS_TEST_TMPDIR/snapshot.json"
  cp "$root_directory/.mise/tests/fixtures/evidence-record.json" "$record"
  cp "$root_directory/.mise/tests/fixtures/evidence-snapshot.json" "$snapshot"
  page="$BATS_TEST_TMPDIR/page"
}

# Runs the task with the environment assignments in $@.
evidence() {
  run env MISE_PROJECT_ROOT="$repository" TF_VAR_state_directory="$BATS_TEST_TMPDIR/state" usage_out="$page" "$@" \
    "$repository/.mise/tasks/evidence.sh"
}

with() {
  evidence usage_record="$record" usage_snapshot="$snapshot" "$@"
}

@test "evidence renders the observed record and the configured snapshot into a static page" {
  with
  [ "$status" -eq 0 ] || fail "$output"
  html=$(cat "$page/index.html")
  [[ "$html" == *"<title>How the cv site is run</title>"* ]]
  [[ "$html" == *"complete"* ]]
  for guarantee in wrong-signer-chart-refused direct-access-denied-gateway-allowed unsigned-image-refused; do
    [[ "$html" == *"$guarantee"* ]] || fail "no row for $guarantee"
  done
  [[ "$html" == *"<h2>Observed</h2>"* && "$html" == *"<h2>Configured</h2>"* && "$html" == *"<h2>Verify</h2>"* ]]
  [[ "$html" == *"require-signed-images"* && "$html" == *"DROPPED x 2"* ]]
  [[ "$html" != *"<script"* ]]
}

@test "evidence escapes markup in a record command and in a snapshot name" {
  jq '.actions[0].command = "<script>alert(1)</script>"' "$record" >"$record.new" && mv "$record.new" "$record"
  jq '.flux.kustomizations[0].name = "<img src=x onerror=1>"' "$snapshot" >"$snapshot.new" && mv "$snapshot.new" "$snapshot"
  with
  [ "$status" -eq 0 ] || fail "$output"
  html=$(cat "$page/index.html")
  [[ "$html" == *"&lt;script&gt;alert(1)&lt;/script&gt;"* ]]
  [[ "$html" == *"&lt;img src=x onerror=1&gt;"* ]]
  [[ "$html" != *"<script"* && "$html" != *"<img"* ]]
}

@test "evidence drops a snapshot field that is not on the allowlist" {
  jq '. + {node_ip: "10.0.0.5", cluster_endpoint: "https://192.168.139.10:6443"}
      | .flux.kustomizations[0].pod = "web-7f9c4-abc12"
      | .hubble.counts[0].source_pod = "probe-7f9c4-abc12"
      | .policies.secret = "hunter2"' "$snapshot" >"$snapshot.new" && mv "$snapshot.new" "$snapshot"
  with
  [ "$status" -eq 0 ] || fail "$output"
  html=$(cat "$page/index.html")
  for leak in 10.0.0.5 192.168.139.10 web-7f9c4-abc12 probe-7f9c4-abc12 hunter2; do
    [[ "$html" != *"$leak"* ]] || fail "the page shows $leak"
  done
}

@test "evidence says a source is unavailable, apart from a source that is empty" {
  jq '.hubble.status = "unavailable" | .hubble.counts = [] | .policies.status = "empty" | .policies.names = []' "$snapshot" >"$snapshot.new" && mv "$snapshot.new" "$snapshot"
  with
  [ "$status" -eq 0 ] || fail "$output"
  html=$(cat "$page/index.html")
  [[ "$html" == *"<strong>Unavailable:</strong>"* ]]
  [[ "$html" == *"No admission policy was found."* ]]
}

@test "evidence labels an incomplete record" {
  jq '.complete = false | .actions = .actions[0:1] | del(.finished)' "$record" >"$record.new" && mv "$record.new" "$record"
  with
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$(cat "$page/index.html")" == *'class="badge">incomplete<'* ]]
  [[ "$output" == *"incomplete record"* ]]
}

@test "evidence refuses a record that does not match the run-record contract" {
  jq '.extra = 1' "$record" >"$record.new" && mv "$record.new" "$record"
  with
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match contracts/run-record"* ]]
}

@test "evidence names the tour when there is no record" {
  evidence usage_snapshot="$snapshot"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise run tour"* ]]
}

@test "evidence takes the newest complete record of the state folder" {
  cp "$record" "$BATS_TEST_TMPDIR/state/evidence/record-20261014T120000Z.json"
  jq '.complete = false | .actions = .actions[0:1] | del(.finished)' "$record" >"$BATS_TEST_TMPDIR/state/evidence/record-20261014T130000Z.json"
  evidence usage_snapshot="$snapshot"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$(cat "$page/index.html")" != *'class="badge">incomplete<'* ]]
}

@test "evidence gives the sha256 of the record and does not claim the commands ran" {
  with
  [ "$status" -eq 0 ] || fail "$output"
  html=$(cat "$page/index.html")
  [[ "$html" == *"sha256 $(shasum -a 256 "$record" | cut -d' ' -f1)"* ]]
  [[ "$html" == *"Nothing on this page proves that the commands ran"* ]]
}
