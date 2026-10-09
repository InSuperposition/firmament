#!/usr/bin/env bats

# The tasks that keep OpenBao's root across a rebuild: openbao:snapshot,
# openbao:restore and openbao:root. A stand-in kubectl plays the pod: its
# root certificate is a line of text, a snapshot is that line plus data.

load stubs.bash

setup() {
  setup_stubs
  pod="$BATS_TEST_TMPDIR/pod"
  mkdir -p "$pod"
  export POD="$pod"
  printf 'ROOT:A\n' >"$pod/root.pem"
  export FIRMAMENT_RESTORE_PAUSE=0
  export FIRMAMENT_OPENBAO_SECONDS=5
  edge_repository
  stub_pod
}

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

run_task() {
  local script="$1"
  MISE_ENV=local TF_VAR_state_directory="$FIRMAMENT_STATE_HOME/environments/local" run "$script"
}

# A repository binding openbao and cert-manager, with the private-state
# manifest the seed task would have written.
edge_repository() {
  MISE_PROJECT_ROOT=$(make_repository environments/local/environment.yaml clusters/singularity/packages.yaml)
  ln -s "$root_directory/contracts" "$MISE_PROJECT_ROOT/contracts"
  printf -- '- package: openbao\n  namespace: openbao\n  tenant: platform\n- package: cert-manager\n  namespace: cert-manager\n  tenant: platform\n' \
    >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  export MISE_PROJECT_ROOT
  record_contracts
  state="$FIRMAMENT_STATE_HOME/environments/local/openbao"
  mkdir -p "$state"
  cp "$root_directory/contracts/private-state/private-state.yaml" "$state/private-state.yaml"
}

# The fake pod. exec runs the remote script's subcommand against files in
# $POD; FAKE_RESTORE_FAILURES makes that many restores fail first,
# FAKE_BAD_READ corrupts the snapshot on its way out, FAKE_NOT_READY makes
# the pod not Ready, FAKE_CHAIN_BAD makes the TLS check fail.
stub_pod() {
  cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
sum() { openssl dgst -sha256 -r | cut -d' ' -f1; }
case "$*" in
  *" get pod openbao-0 "*) [[ -z "${FAKE_NOT_READY:-}" ]] && printf True ;;
  *" wait "*) [[ -z "${FAKE_NOT_READY:-}" ]] ;;
  *" delete pod "*)
    # A restart serves the restored root.
    [[ -f "$POD/received" ]] && head -n 1 "$POD/received" >"$POD/root.pem"
    exit 0 ;;
  *" port-forward "*)
    printf 'Forwarding from 127.0.0.1:%s -> 8443\n' "$((20000 + RANDOM % 20000))"
    exec sleep 30 ;;
  *" exec "*)
    case "${*: -1}" in
      root) cat "$POD/root.pem" ;;
      save)
        { cat "$POD/root.pem"; printf 'data\n'; } >"$POD/snap"
        printf 'Saved the snapshot\n'; sum <"$POD/snap" ;;
      read)
        cat "$POD/snap"
        [[ -z "${FAKE_BAD_READ:-}" ]] || printf 'garbage' ;;
      receive) cat >"$POD/received" ;;
      restore)
        sum <"$POD/received"
        count=$(cat "$POD/failures" 2>/dev/null || printf '%s' "${FAKE_RESTORE_FAILURES:-0}")
        if ((count > 0)); then printf '%s' "$((count - 1))" >"$POD/failures"; echo "unexpected EOF" >&2; exit 1; fi ;;
    esac ;;
esac
STUB
  chmod +x "$stubs/kubectl"
  cat >"$stubs/openssl" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == s_client ]]; then
  printf 'openssl %s\n' "\$*" >>"\$CALLS"
  [[ -z "\${FAKE_CHAIN_BAD:-}" ]]
  exit
fi
exec $(command -v openssl) "\$@"
STUB
  chmod +x "$stubs/openssl"
}

fingerprint_of() {
  printf '%s\n' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
}

local_state() {
  printf '{"version": 4}\n' >"$FIRMAMENT_STATE_HOME/environments/local/machine-orb.tfstate"
  printf '{"version": 4}\n' >"$FIRMAMENT_STATE_HOME/environments/local/kubernetes-k0s.tfstate"
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

@test "openbao:snapshot saves the first snapshot, mode 0600, with the root's fingerprint" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(mode_of "$state/snapshot.snap")" = 600 ]
  [ "$(yq -r .openbao.snapshot.root_fingerprint "$state/private-state.yaml")" = "$(fingerprint_of ROOT:A)" ]
  [ "$(yq -r '.openbao.snapshot_previous // "none"' "$state/private-state.yaml")" = none ]
}

@test "openbao:snapshot keeps the snapshot before the newest as the previous generation" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  cp "$state/snapshot.snap" "$BATS_TEST_TMPDIR/first"
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  cmp "$state/snapshot.prev.snap" "$BATS_TEST_TMPDIR/first"
  [ "$(yq -r .openbao.snapshot_previous.path "$state/private-state.yaml")" = snapshot.prev.snap ]
  [ "$(mode_of "$state/snapshot.prev.snap")" = 600 ]
}

@test "openbao:snapshot refuses to save when the live root differs, naming both, and keeps the snapshot" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  cp "$state/snapshot.snap" "$BATS_TEST_TMPDIR/first"
  printf 'ROOT:B\n' >"$pod/root.pem"
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$(fingerprint_of ROOT:A)"* && "$output" == *"$(fingerprint_of ROOT:B)"* ]] || fail "$output"
  cmp "$state/snapshot.snap" "$BATS_TEST_TMPDIR/first"
}

@test "openbao:snapshot stops on a snapshot file the manifest does not name" {
  printf 'earlier' >"$state/snapshot.snap"
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$state/snapshot.snap"* ]] || fail "$output"
  [ "$(cat "$state/snapshot.snap")" = earlier ]
}

@test "openbao:snapshot saves nothing when the snapshot changed on the way out" {
  FAKE_BAD_READ=1 run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed on the way out"* ]] || fail "$output"
  [ ! -e "$state/snapshot.snap" ]
  [ "$(yq -r '.openbao.snapshot // "none"' "$state/private-state.yaml")" = none ]
}

@test "openbao:snapshot does nothing when the cluster does not bind openbao" {
  printf -- '- package: cilium\n  namespace: kube-system\n  tenant: platform\n' >"$MISE_PROJECT_ROOT/clusters/singularity/packages.yaml"
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"nothing to save"* ]]
}

@test "openbao:restore does nothing when no snapshot is recorded" {
  run_task "$root_directory/.mise/tasks/openbao/restore.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"nothing to restore"* ]]
  ! grep -q 'exec' "$CALLS"
}

@test "openbao:restore skips when the live root is the snapshot's" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  run_task "$root_directory/.mise/tasks/openbao/restore.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ ! -e "$pod/received" ]
}

@test "openbao:restore brings the old root back into a rebuilt OpenBao and restarts its pod" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  [ "$status" -eq 0 ] || fail "$output"
  printf 'ROOT:B\n' >"$pod/root.pem"
  rm -f "$pod/received"
  run_task "$root_directory/.mise/tasks/openbao/restore.sh"
  [ "$status" -eq 0 ] || fail "$output"
  cmp "$pod/received" "$state/snapshot.snap"
  grep -q 'delete pod openbao-0' "$CALLS"
  [ "$(cat "$pod/root.pem")" = ROOT:A ]
}

@test "openbao:restore retries four failures and then succeeds" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  printf 'ROOT:B\n' >"$pod/root.pem"
  FAKE_RESTORE_FAILURES=4 run_task "$root_directory/.mise/tasks/openbao/restore.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(grep -c 'restore$' "$CALLS" || true)" -ge 5 ]
}

@test "openbao:restore gives up after five failures and never restarts the pod" {
  run_task "$root_directory/.mise/tasks/openbao/snapshot.sh"
  printf 'ROOT:B\n' >"$pod/root.pem"
  FAKE_RESTORE_FAILURES=9 run_task "$root_directory/.mise/tasks/openbao/restore.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after 5 attempts"* ]] || fail "$output"
  ! grep -q 'delete pod' "$CALLS"
}

@test "openbao:root publishes the root as a Secret in the cert-manager namespace" {
  run_task "$root_directory/.mise/tasks/openbao/root.sh"
  [ "$status" -eq 0 ] || fail "$output"
  grep -q -- '-n cert-manager create secret generic openbao-root --from-file=ca.crt=' "$CALLS"
  grep -q 'apply -f -' "$CALLS"
}

@test "openbao:root publishes nothing when the listener's certificate does not chain to the root" {
  FAKE_CHAIN_BAD=1 run_task "$root_directory/.mise/tasks/openbao/root.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not present a certificate chained"* ]] || fail "$output"
  ! grep -q 'apply -f -' "$CALLS"
}

@test "env:destroy saves the snapshot before it destroys anything" {
  local_state
  run_task "$root_directory/.mise/tasks/env/destroy.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(grep -n 'mise run openbao:snapshot' "$CALLS" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^tofu .*destroy' "$CALLS" | head -n 1 | cut -d: -f1)" ]
}

@test "env:destroy stops before destroying anything when the save fails" {
  local_state
  printf '#!/usr/bin/env bash\nprintf "mise %%s\\n" "$*" >>"$CALLS"\n[[ "$*" != "run openbao:snapshot" ]]\n' >"$stubs/mise"
  run_task "$root_directory/.mise/tasks/env/destroy.sh"
  [ "$status" -ne 0 ]
  ! grep -q '^tofu .*destroy' "$CALLS"
}

@test "env:destroy warns and goes on when OpenBao is not reachable" {
  FAKE_NOT_READY=1 run_task "$root_directory/.mise/tasks/env/destroy.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"snapshot from the last apply is the one kept"* ]] || fail "$output"
}
