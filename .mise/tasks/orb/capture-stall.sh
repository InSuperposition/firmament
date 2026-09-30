#!/usr/bin/env bash
#MISE description="Capture OrbStack SSH and network state right after a stall, without changing anything"
#USAGE arg "[machine]" default="local-workload" help="OrbStack machine name"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
machine="$usage_machine"

# The machine name comes from the argument, not from tofu state: a stall
# happens mid-apply, before the state records the machine's outputs.
capture_directory="${FIRMAMENT_STATE_HOME:?FIRMAMENT_STATE_HOME is unset; run this through mise}/stalls/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$capture_directory"

# Writes one command, its output and its exit status to <name>.txt. A stalled
# machine can hang any command, so each one gets FIRMAMENT_CAPTURE_SECONDS
# (default 30); exit 124 means it timed out, which is itself evidence. orb
# ignores TERM while stalled, so a command still running that many seconds
# later is killed, exit 137. A failure never stops the capture. Each command
# stays in the terminal's foreground process group: `orb -m` sets terminal
# modes, which stops a process that timeout has moved to a background group
# until it times out, and that would look like a stall.
capture_seconds="${FIRMAMENT_CAPTURE_SECONDS:-30}"
capture() {
  local file="$capture_directory/$1.txt" status=0
  shift
  printf '$ %s\n' "$*" >"$file"
  timeout --foreground -k "$capture_seconds" "$capture_seconds" "$@" >>"$file" 2>&1 || status=$?
  printf 'exit %s\n' "$status" >>"$file"
}

# Host side first: ARP entries and DNS answers are the most short-lived.
capture host-arp arp -an
capture host-dns dscacheutil -q host -a name "$machine.orb.local"
capture host-route route -n get "$machine.orb.local"
capture host-ssh-proxy lsof -nP -iTCP:32222
capture machine-info orb info "$machine" --format json
capture machine-sockets orb -m "$machine" -u root ss -tnp
capture machine-ssh-journal orb -m "$machine" -u root journalctl -u ssh --since -1h --no-pager

# orb report uploads its diagnostic zip to OrbStack after a review prompt.
# Without a terminal the prompt takes its default and uploads unreviewed, so
# it runs only when someone can answer.
if [[ -t 0 ]]; then
  orb report
else
  printf 'Skipped orb report: no terminal to review it. Run it by hand.\n' >&2
fi

printf 'Captured in %s\n' "$capture_directory"
