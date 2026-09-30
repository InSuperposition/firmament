# shellcheck shell=bash
# Checks that a machine is ready for k0s: Ubuntu 26.04 on a supported
# architecture, systemd, cgroup v2, kernel BTF, passwordless sudo, curl
# and systemctl.

# Prints the machine's facts as key=value lines, read as root over the orb
# CLI.
ubuntu_facts() {
  orb -m "$1" -u root bash -s <<'REMOTE'
set -eu
. /etc/os-release
printf 'id=%s\n' "$ID"
printf 'version_id=%s\n' "$VERSION_ID"
printf 'arch=%s\n' "$(uname -m)"
printf 'init=%s\n' "$(ps -p 1 -o comm= | tr -d ' ')"
printf 'cgroup=%s\n' "$(stat -fc %T /sys/fs/cgroup)"
if test -r /sys/kernel/btf/vmlinux; then printf 'btf=present\n'; else printf 'btf=missing\n'; fi
if sudo -n true 2>/dev/null; then printf 'sudo=available\n'; else printf 'sudo=missing\n'; fi
for command_name in curl systemctl; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'command_%s=present\n' "$command_name"
  else
    printf 'command_%s=missing\n' "$command_name"
  fi
done
REMOTE
}

# Fails unless the machine meets every requirement, naming each one it
# misses and what it found instead.
check_ubuntu_ready() {
  local machine="$1" facts status=0 name wanted message found
  facts=$(ubuntu_facts "$machine") ||
    fail "$machine: cannot read its facts over the orb CLI" || return
  while IFS="|" read -r name wanted message; do
    found=$(sed -n "s/^$name=//p" <<<"$facts")
    [[ -n "$found" && " $wanted " == *" $found "* ]] && continue
    printf "%s: %s (%s is %s)\n" "$machine" "$message" "$name" "${found:-unknown}" >&2
    status=1
  done <<"REQUIREMENTS"
id|ubuntu|Ubuntu is required
version_id|26.04|Ubuntu 26.04 is required
arch|aarch64 arm64 x86_64|an arm64 or x86_64 host is required
init|systemd|systemd is required as PID 1
cgroup|cgroup2fs|cgroup v2 is required
btf|present|kernel BTF is required
sudo|available|passwordless sudo is required
command_curl|present|curl is required
command_systemctl|present|systemctl is required
REQUIREMENTS
  return "$status"
}
