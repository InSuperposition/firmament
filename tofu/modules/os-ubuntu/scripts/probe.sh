#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

query=$(cat)
target=$(jq -er '.target' <<<"$query") || fail 'target is required.'
port=$(jq -r '.port // empty' <<<"$query")
identity_file=$(jq -r '.identity_file // empty' <<<"$query")

ssh_args=(
  -o BatchMode=yes
  -o ConnectTimeout=10
)
[[ -n "$port" ]] && ssh_args+=(-p "$port")
[[ -n "$identity_file" ]] && ssh_args+=(-i "$identity_file")

remote_script=$(
  cat <<'REMOTE'
set -eu
. /etc/os-release
printf 'id=%s\n' "$ID"
printf 'version_id=%s\n' "$VERSION_ID"
printf 'arch=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'init=%s\n' "$(ps -p 1 -o comm= | tr -d ' ')"
printf 'cgroup=%s\n' "$(stat -fc %T /sys/fs/cgroup)"
if test -r /sys/kernel/btf/vmlinux; then
  printf 'btf=present\n'
else
  printf 'btf=missing\n'
fi
if sudo -n true 2>/dev/null; then
  printf 'sudo=available\n'
else
  printf 'sudo=missing\n'
fi
for command_name in curl systemctl; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'command_%s=present\n' "$command_name"
  else
    printf 'command_%s=missing\n' "$command_name"
  fi
done
REMOTE
)

result=$(ssh "${ssh_args[@]}" "$target" bash -s <<<"$remote_script") ||
  fail "Unable to inspect Ubuntu host through SSH: $target"

jq -Rn '
  [inputs | select(length > 0) | split("=") | {(.[0]): .[1]}] | add
' <<<"$result"
