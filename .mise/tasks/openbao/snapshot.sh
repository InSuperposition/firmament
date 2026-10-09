#!/usr/bin/env bash
#MISE description="Save a Raft snapshot of OpenBao into private state, keeping the one before it; refuses to save when the live root differs from the one the snapshot holds, so an empty rebuilt OpenBao never replaces the good copy"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-openbao.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-openbao.sh"

status=0
openbao_context || status=$?
if ((status == 3)); then
  printf 'openbao is not bound in this cluster; nothing to save\n'
  exit 0
fi
((status == 0)) || exit "$status"
[[ -f "$ob_manifest" ]] || fail "no private-state manifest at $ob_manifest; run mise run openbao:seed first" || exit
check_manifest_contract "$ob_manifest" || exit

readonly snapshot_file=snapshot.snap
readonly previous_file=snapshot.prev.snap
recorded=$(recorded_fingerprint snapshot) || exit

# The guard (C113). A snapshot file the manifest does not name is a save that
# stopped between its two renames: nothing may overwrite it.
if [[ -z "$recorded" && -e "$ob_state/$snapshot_file" ]]; then
  fail "$ob_state/$snapshot_file exists but the manifest has no snapshot entry; a save was interrupted. Check the file, then add the entry or remove the file." || exit
fi

openbao_wait_ready || exit
live=$(openbao_live_fingerprint) || exit
if [[ -n "$recorded" && "$live" != "$recorded" ]]; then
  fail "not saving: OpenBao's root fingerprint is $live but the snapshot holds $recorded. Run mise run openbao:restore, or remove the snapshot entry on purpose to start over." || exit
fi

# Take the snapshot in the pod, stream it out and compare checksums.
remote_sum=$(openbao_remote save) || fail "OpenBao refused the snapshot" || exit
remote_sum=${remote_sum##*$'\n'}
# Temp files sit beside the real ones, so the renames stay on one filesystem.
temp_directory=$(umask 077 && mktemp -d "$ob_state/.save.XXXXXX")
trap 'rm -rf "$temp_directory"' EXIT
temp_snapshot="$temp_directory/$snapshot_file"
temp_manifest="$temp_directory/private-state.yaml"
openbao_remote read >"$temp_snapshot" || exit
chmod 0600 "$temp_snapshot"
local_sum=$(sha256_hex <"$temp_snapshot")
[[ "$local_sum" == "$remote_sum" ]] ||
  fail "the snapshot changed on the way out: the pod has $remote_sum, the Mac has $local_sum; nothing was saved" || exit

# The manifest is written first as a temp file naming the final paths, the
# previous generation moves aside, then the two renames: a crash between them
# leaves a file the manifest names or the guard above refuses to overwrite.
cp "$ob_manifest" "$temp_manifest"
chmod 0600 "$temp_manifest"
if [[ -n "$recorded" && -e "$ob_state/$snapshot_file" ]]; then
  yq -i ".openbao.snapshot_previous = {\"path\": \"$previous_file\", \"mode\": \"0600\", \"root_fingerprint\": \"$recorded\"}" "$temp_manifest"
fi
yq -i ".openbao.snapshot = {\"path\": \"$snapshot_file\", \"mode\": \"0600\", \"root_fingerprint\": \"$live\"}" "$temp_manifest"
check_manifest_contract "$temp_manifest" || exit

if [[ -e "$ob_state/$snapshot_file" ]]; then
  mv -f "$ob_state/$snapshot_file" "$ob_state/$previous_file"
fi
mv -f "$temp_snapshot" "$ob_state/$snapshot_file"
mv -f "$temp_manifest" "$ob_manifest"
printf 'saved the OpenBao snapshot (root %s)\n' "$live"
