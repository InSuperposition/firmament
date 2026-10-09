#!/usr/bin/env bash
#MISE description="Create OpenBao's seal key Secret and operator CA ConfigMap from private state, generating the secret files that are missing; never overwrites a file, and stops when the private state is damaged"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null

# The names the OpenBao config mounts: packages/openbao/config/render.cue.
readonly seal_secret=openbao-static-seal
readonly operator_ca_configmap=openbao-operator-ca

cluster=$(cluster_directory) || exit
namespace=$(yq -r '.[] | select(.package == "openbao") | .namespace' "$cluster/packages.yaml" 2>/dev/null) || namespace=""
if [[ -z "$namespace" ]]; then
  printf 'openbao is not bound in this cluster; nothing to seed\n'
  exit 0
fi

state="${TF_VAR_state_directory:?}/openbao"
manifest="$state/private-state.yaml"
common_name=$(yq -r '.operator.common_name' "$cluster/openbao.yaml") || exit
[[ -n "$common_name" && "$common_name" != null ]] || fail "$cluster/openbao.yaml has no operator.common_name" || exit

# Prints a file's mode as four octal digits, on macOS and on Linux.
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# Generates the secret files private state lacks. A file that exists is never
# touched: a new seal key could not unseal what the old one protected.
generate_missing_files() {
  (
    umask 077
    mkdir -p "$state"
    [[ -e "$state/seal.key" ]] || openssl rand -out "$state/seal.key" 32
    if [[ ! -e "$state/operator-ca.key" || ! -e "$state/operator-ca.pem" ]]; then
      [[ ! -e "$state/operator-ca.key" && ! -e "$state/operator-ca.pem" ]] ||
        fail "private state has only half of the operator CA in $state; restore the missing file or remove both" || exit
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$state/operator-ca.key" -out "$state/operator-ca.pem" -subj "/CN=firmament operator CA" 2>/dev/null
    fi
    if [[ ! -e "$state/operator-client.key" || ! -e "$state/operator-client.pem" ]]; then
      [[ ! -e "$state/operator-client.key" && ! -e "$state/operator-client.pem" ]] ||
        fail "private state has only half of the operator client certificate in $state; restore the missing file or remove both" || exit
      csr=$(mktemp)
      trap 'rm -f "$csr"' EXIT
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$state/operator-client.key" -out "$csr" -subj "/CN=$common_name" 2>/dev/null
      openssl x509 -req -in "$csr" -CA "$state/operator-ca.pem" -CAkey "$state/operator-ca.key" \
        -set_serial "0x$(openssl rand -hex 8)" -days 3650 -extfile <(printf 'extendedKeyUsage=clientAuth\n') \
        -out "$state/operator-client.pem" 2>/dev/null
    fi
    chmod 0644 "$state/operator-ca.pem" "$state/operator-client.pem"
  )
}

# Fails, naming the file, when the manifest names a file that is missing or
# has the wrong mode.
check_manifest_files() {
  local entry path mode actual
  for entry in seal_key operator_ca.certificate operator_ca.key operator_client.certificate operator_client.key; do
    path=$(yq -r ".openbao.$entry.path" "$manifest") || return
    mode=$(yq -r ".openbao.$entry.mode" "$manifest") || return
    if [[ ! -f "$state/$path" ]]; then
      fail "private state is damaged: $state/$path ($entry) is missing; restore it from a backup. Generating a new one would leave the existing OpenBao data sealed forever." || return
    fi
    actual=$(file_mode "$state/$path")
    if [[ "$actual" != "${mode#0}" ]]; then
      fail "private state: $state/$path ($entry) has mode $actual, the manifest says $mode" || return
    fi
  done
}

write_manifest() {
  (
    umask 077
    cp "$MISE_PROJECT_ROOT/contracts/private-state/private-state.yaml" "$manifest.new"
    mv "$manifest.new" "$manifest"
  )
}

if [[ -e "$manifest" ]]; then
  cue vet -c -d '#Contract' "$MISE_PROJECT_ROOT/contracts/private-state/schema.cue" "$manifest" ||
    fail "$manifest does not match the private-state contract" || exit
  check_manifest_files || exit
else
  generate_missing_files || exit
  write_manifest
  check_manifest_files || exit
  printf 'generated the OpenBao secret files in %s\n' "$state"
fi

kubeconfig=$(environment_kubeconfig) || exit
timeout_seconds="${FIRMAMENT_SEED_SECONDS:-300}"
deadline=$((SECONDS + timeout_seconds))
until kubectl --kubeconfig "$kubeconfig" get namespace "$namespace" >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    fail "namespace $namespace did not appear within ${timeout_seconds}s; Flux creates it from the pushed commit" || exit
  fi
  sleep 5
done

kubectl --kubeconfig "$kubeconfig" -n "$namespace" create secret generic "$seal_secret" \
  --from-file=seal.key="$state/seal.key" --dry-run=client -o yaml |
  kubectl --kubeconfig "$kubeconfig" apply -f - >/dev/null
kubectl --kubeconfig "$kubeconfig" -n "$namespace" create configmap "$operator_ca_configmap" \
  --from-file=operator-ca.pem="$state/operator-ca.pem" --dry-run=client -o yaml |
  kubectl --kubeconfig "$kubeconfig" apply -f - >/dev/null
printf 'seeded secret/%s and configmap/%s in namespace %s\n' "$seal_secret" "$operator_ca_configmap" "$namespace"
