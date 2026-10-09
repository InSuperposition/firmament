#!/usr/bin/env bash
#MISE description="Publish OpenBao's root certificate as Secret openbao-root in the cert-manager namespace, after checking that OpenBao's own listener presents a certificate chained to it"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-openbao.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-openbao.sh"

status=0
openbao_context || status=$?
if ((status == 3)); then
  printf 'openbao is not bound in this cluster; nothing to publish\n'
  exit 0
fi
((status == 0)) || exit "$status"
[[ -n "$ob_issuer_namespace" ]] || fail "cert-manager is not bound in this cluster; the root Secret has no namespace" || exit

openbao_wait_ready || exit
root=$(mktemp)
forward_log=$(mktemp)
forward_pid=""
cleanup() {
  [[ -z "$forward_pid" ]] || kill "$forward_pid" 2>/dev/null || true
  rm -f "$root" "$forward_log"
}
trap cleanup EXIT
openbao_live_root >"$root" || exit
[[ -s "$root" ]] || fail "OpenBao returned an empty root certificate" || exit

# The listener's certificate came from the PKI through ACME. After a restore
# the cache could still hold one from the root that was replaced: publishing
# the restored root then would make every Issuer login fail on trust.
openbao_kubectl -n "$ob_namespace" port-forward "pod/$OPENBAO_POD" :8443 >"$forward_log" 2>&1 &
forward_pid=$!
port=""
for _ in $(seq 1 50); do
  port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) ->.*/\1/p' "$forward_log" | head -n 1)
  [[ -z "$port" ]] || break
  sleep 0.2
done
[[ -n "$port" ]] || fail "could not forward to OpenBao's listener: $(cat "$forward_log")" || exit
if ! openssl s_client -connect "127.0.0.1:$port" -servername "openbao.$ob_namespace.svc" \
  -CAfile "$root" -verify_return_error </dev/null >/dev/null 2>&1; then
  fail "OpenBao's listener does not present a certificate chained to the root it publishes; restart the pod and run again" || exit
fi

# Flux creates the namespace from the pushed commit.
deadline=$((SECONDS + ${FIRMAMENT_OPENBAO_SECONDS:-900}))
until openbao_kubectl get namespace "$ob_issuer_namespace" >/dev/null 2>&1; do
  ((SECONDS < deadline)) || fail "namespace $ob_issuer_namespace did not appear; Flux creates it from the pushed commit" || exit
  sleep 5
done

openbao_kubectl -n "$ob_issuer_namespace" create secret generic openbao-root \
  --from-file=ca.crt="$root" --dry-run=client -o yaml |
  openbao_kubectl apply -f - >/dev/null
printf 'published secret/openbao-root in namespace %s\n' "$ob_issuer_namespace"
