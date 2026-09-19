#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

mode=${1:-bootstrap}
[[ $# -le 1 && ("$mode" == bootstrap || "$mode" == adopt) ]] || fail 'Expected bootstrap or adopt.'
orb_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target="$orb_directory/machine.json"
jq -e -L "$orb_directory" 'include "machine-schema"; valid_target' "$target" \
  >/dev/null || fail "Invalid machine configuration: $target"
name=$(jq -er '.name | select(type == "string" and test("^[a-z][a-z0-9-]*$"))' "$target")
state_directory="${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/$name/orb"
marker="$state_directory/ownership.json"
mkdir -p "$state_directory"
mkdir "$state_directory/.lock" 2>/dev/null || fail "Target lock exists: $state_directory/.lock"
temporary_marker=''
cleanup() {
  if [[ -n "$temporary_marker" ]]; then
    rm -f -- "$temporary_marker"
  fi
  rmdir "$state_directory/.lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

machines=$(orb list --format json) || fail 'OrbStack unavailable; no machine changes made.'
jq -e 'type == "array" and all(.[]; type == "object" and (.name | type == "string"))' \
  <<<"$machines" >/dev/null || fail 'Invalid OrbStack machine list.'
count=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' <<<"$machines")
created=false
if [[ "$count" == 0 ]]; then
  [[ "$mode" == bootstrap ]] || fail "Cannot adopt absent machine: $name"
  [[ ! -e "$marker" ]] || fail "Owned machine is missing: $name; refusing automatic recreation."
  arch=$(jq -er '.image.arch' "$target")
  image=$(jq -er '.image | .distro + ":" + .version' "$target")
  cpus=$(jq -er '.cpus' "$target")
  memory=$(jq -er '.memory_mib' "$target")
  disk=$(jq -er '.disk_gib' "$target")
  orb create --arch "$arch" --cpus "$cpus" --memory "${memory}M" \
    --disk "${disk}G" "$image" "$name" >&2 || fail "Creation failed: $name; ownership not recorded."
  created=true
elif [[ "$count" != 1 ]]; then
  fail "Ambiguous machine name: $name"
fi

info=$(orb info "$name" --format json) || fail "Cannot inspect machine: $name"
jq -e -L "$orb_directory" --slurpfile target "$target" \
  'include "machine-schema"; matches_target($target[0])' \
  <<<"$info" >/dev/null || fail "Machine configuration does not match $target; no ownership changes made."
machine_id=$(jq -er '.record.id' <<<"$info")
if [[ "$created" == false ]]; then
  listed_id=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .id' <<<"$machines")
  [[ "$machine_id" == "$listed_id" ]] || fail 'Machine identity changed during inspection.'
fi

if [[ "$mode" == bootstrap && "$created" == false ]]; then
  [[ -f "$marker" ]] || fail "Machine is unmarked; run mise run orb:adopt to adopt $name explicitly."
  owned_id=$(jq -er '.machine_id | select(type == "string" and length > 0)' "$marker") ||
    fail 'Invalid ownership marker; inspect it before using orb:adopt.'
  [[ "$owned_id" == "$machine_id" ]] || fail 'Machine was replaced; run mise run orb:adopt explicitly.'
else
  temporary_marker=$(mktemp "$state_directory/ownership.XXXXXX")
  jq -n --arg id "$machine_id" '{machine_id: $id}' >"$temporary_marker"
  mv -- "$temporary_marker" "$marker"
  temporary_marker=''
  printf 'Recorded ownership of %s (%s).\n' "$name" "$machine_id" >&2
fi
printf '%s\n' "$info"
