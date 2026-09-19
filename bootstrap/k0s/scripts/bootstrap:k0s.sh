#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

mode=${1:-apply}
[[ $# -le 1 ]] || fail 'Expected render, dry-run, or apply.'
case "$mode" in
render | dry-run | apply) ;;
*) fail 'Expected render, dry-run, or apply.' ;;
esac

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_directory=$(cd -- "$script_directory/../../.." && pwd)
contract="$root_directory/bootstrap/k0s/k0sctl.yaml"
state_directory=${FIRMAMENT_K0S_STATE_DIRECTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/firmament/targets/firmament/k0s}
rendered="$state_directory/k0sctl.rendered.yaml"
kubeconfig="$state_directory/admin.kubeconfig"

require_value() {
  local name=$1 value=${!1:-}
  [[ -n "$value" ]] || fail "$name is required."
}

require_value FIRMAMENT_K0S_SSH_ADDRESS
require_value FIRMAMENT_K0S_SSH_USER
require_value FIRMAMENT_K0S_SSH_PORT
require_value FIRMAMENT_K0S_SSH_KEY
require_value FIRMAMENT_K0S_API_ADDRESS

[[ "$FIRMAMENT_K0S_SSH_ADDRESS" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'invalid SSH address.'
[[ "$FIRMAMENT_K0S_SSH_USER" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail 'invalid SSH user.'
[[ "$FIRMAMENT_K0S_SSH_PORT" =~ ^[0-9]+$ ]] || fail 'invalid SSH port.'
((FIRMAMENT_K0S_SSH_PORT >= 1 && FIRMAMENT_K0S_SSH_PORT <= 65535)) || fail 'invalid SSH port.'
[[ "$FIRMAMENT_K0S_SSH_KEY" == /* && "$FIRMAMENT_K0S_SSH_KEY" != *$'\n'* ]] || fail 'invalid SSH key path.'
[[ "$FIRMAMENT_K0S_API_ADDRESS" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'invalid API address.'

mkdir -p "$state_directory"
mkdir "$state_directory/.lock" 2>/dev/null || fail "k0s target lock exists: $state_directory/.lock"
temporary=''
cleanup() {
  [[ -z "$temporary" ]] || rm -f -- "$temporary"
  rmdir "$state_directory/.lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

render_config() {
  local output
  output=$(mktemp "$state_directory/k0sctl.rendered.XXXXXX")
  temporary=$output
  yq eval '
    .spec.hosts[0].ssh.address = strenv(FIRMAMENT_K0S_SSH_ADDRESS) |
    .spec.hosts[0].ssh.user = strenv(FIRMAMENT_K0S_SSH_USER) |
    .spec.hosts[0].ssh.port = (strenv(FIRMAMENT_K0S_SSH_PORT) | tonumber) |
    .spec.hosts[0].ssh.keyPath = strenv(FIRMAMENT_K0S_SSH_KEY) |
    .spec.k0s.config.spec.api.externalAddress = strenv(FIRMAMENT_K0S_API_ADDRESS)
  ' "$contract" >"$output" || fail 'Unable to render k0sctl configuration.'
  yq -e '
    .apiVersion == "k0sctl.k0sproject.io/v1beta1" and
    .kind == "Cluster" and
    (.spec.hosts | length == 1) and
    (.spec.hosts[0].ssh.address | length > 0) and
    (.spec.hosts[0].ssh.user | length > 0) and
    (.spec.hosts[0].ssh.keyPath | length > 0) and
    (.spec.k0s.config.spec.api.externalAddress | length > 0)
  ' "$output" >/dev/null || fail 'Rendered k0sctl configuration failed validation.'
  mv -- "$output" "$rendered"
  temporary=''
}

render_config
case "$mode" in
render)
  printf '%s\n' "$rendered"
  ;;
dry-run)
  k0sctl apply --dry-run --config "$rendered"
  ;;
apply)
  k0sctl apply \
    --config "$rendered" \
    --kubeconfig-out "$kubeconfig" \
    --kubeconfig-api-address "$FIRMAMENT_K0S_API_ADDRESS" \
    --kubeconfig-cluster firmament
  chmod 0600 "$kubeconfig"
  kubectl --kubeconfig "$kubeconfig" get nodes --request-timeout=30s
  ;;
esac
