#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

target=${FIRMAMENT_SSH_TARGET:-}
[[ -n "$target" ]] || fail 'FIRMAMENT_SSH_TARGET is required.'

ssh_args=(
  -o BatchMode=yes
  -o ConnectTimeout=10
)
if [[ -n "${FIRMAMENT_SSH_PORT:-}" ]]; then
  ssh_args+=(-p "$FIRMAMENT_SSH_PORT")
fi
if [[ -n "${FIRMAMENT_SSH_IDENTITY_FILE:-}" ]]; then
  ssh_args+=(-i "$FIRMAMENT_SSH_IDENTITY_FILE")
fi

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

get_value() {
  local key=$1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); found = 1 } END { if (!found) exit 1 }' <<<"$result"
}

[[ "$(get_value id)" == ubuntu ]] || fail 'Host is not Ubuntu.'
[[ "$(get_value version_id)" == 26.04 ]] || fail 'Ubuntu 26.04 is required.'
[[ "$(get_value arch)" == aarch64 || "$(get_value arch)" == arm64 || "$(get_value arch)" == x86_64 ]] ||
  fail 'Unsupported host architecture.'
[[ "$(get_value init)" == systemd ]] || fail 'systemd is required as PID 1.'
[[ "$(get_value cgroup)" == cgroup2fs ]] || fail 'cgroup v2 is required.'
[[ "$(get_value btf)" == present ]] || fail 'Kernel BTF is required.'
[[ "$(get_value sudo)" == available ]] || fail 'Passwordless sudo is required for k0sctl.'
[[ "$(get_value command_curl)" == present ]] || fail 'curl is required on the host.'
[[ "$(get_value command_systemctl)" == present ]] || fail 'systemctl is required on the host.'

printf '%s\n' "$result"
