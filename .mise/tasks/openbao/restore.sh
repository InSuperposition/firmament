#!/usr/bin/env bash
#MISE description="Restore OpenBao from the snapshot in private state when the live root differs from the one the snapshot holds, then restart its pod; does nothing when they match or no snapshot exists"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-openbao.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-openbao.sh"

status=0
openbao_context || status=$?
if ((status == 3)); then
  printf 'openbao is not bound in this cluster; nothing to restore\n'
  exit 0
fi
((status == 0)) || exit "$status"

if [[ ! -f "$ob_manifest" ]]; then
  fail "no private-state manifest at $ob_manifest; run mise run openbao:seed first" || exit
fi
check_manifest_contract "$ob_manifest" || exit
recorded=$(recorded_fingerprint snapshot) || exit
if [[ -z "$recorded" ]]; then
  printf 'no snapshot recorded; nothing to restore\n'
  exit 0
fi
file="$ob_state/$(recorded_path snapshot)"
[[ -f "$file" ]] || fail "the manifest names $file but it is missing; restore it from a backup" || exit

openbao_wait_ready || exit
live=$(openbao_live_fingerprint) || exit
if [[ "$live" == "$recorded" ]]; then
  printf 'OpenBao already holds the snapshot'\''s root; nothing to restore\n'
  exit 0
fi

# kubectl exec drops part of a long stdin stream about half the time (the pod
# then holds a multiple of 32 KiB and OpenBao answers `unexpected EOF`). Resend
# until the pod's checksum equals the Mac's, then restore; both steps are bounded.
sends=10
attempts=5
pause="${FIRMAMENT_RESTORE_PAUSE:-10}"
want_sum=$(sha256_hex <"$file")
for ((send = 1; send <= sends; send++)); do
  pod_sum=$(openbao_remote receive <"$file") || exit
  pod_sum=${pod_sum##*$'\n'}
  [[ "$pod_sum" == "$want_sum" ]] && break
  if ((send == sends)); then
    fail "the snapshot did not reach the pod whole after $sends sends: the Mac has $want_sum, the pod has $pod_sum" || exit
  fi
done
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if output=$(openbao_remote restore 2>&1); then
    break
  fi
  if ((attempt == attempts)); then
    printf '%s\n' "$output" >&2
    fail "OpenBao did not accept the snapshot after $attempts attempts" || exit
  fi
  sleep "$pause"
done

# The pod restarts: its listener certificate came from the root it just
# replaced, and the restart gets a new one from the restored root.
openbao_kubectl -n "$ob_namespace" delete pod "$OPENBAO_POD" --wait=true >/dev/null || exit
openbao_wait_ready || exit
after=$(openbao_live_fingerprint) || exit
[[ "$after" == "$recorded" ]] ||
  fail "after the restore OpenBao's root is $after, not the snapshot's $recorded" || exit
printf 'restored the OpenBao snapshot (root %s)\n' "$after"
