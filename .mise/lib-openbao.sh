# shellcheck shell=bash
# Helpers for the openbao:snapshot, openbao:restore and openbao:root tasks:
# they reach OpenBao by `kubectl exec` into its pod, because the pod network
# is not reachable from the Mac. Source after lib.sh.

readonly OPENBAO_POD=openbao-0
readonly OPENBAO_CONTAINER=openbao
readonly OPENBAO_REMOTE_SCRIPT=.mise/remote/openbao-snapshot.sh

# Sets the globals the other helpers read: the namespaces OpenBao and
# cert-manager are bound in, the private-state folder and manifest, and the
# kubeconfig. Returns 3 when the cluster does not bind OpenBao.
openbao_context() {
  local cluster
  require_environment >/dev/null || return
  cluster=$(cluster_directory) || return
  ob_namespace=$(yq -r '.[] | select(.package == "openbao") | .namespace' "$cluster/packages.yaml" 2>/dev/null) || ob_namespace=""
  [[ -n "$ob_namespace" ]] || return 3
  # shellcheck disable=SC2034 # read by openbao:root
  ob_issuer_namespace=$(yq -r '.[] | select(.package == "cert-manager") | .namespace' "$cluster/packages.yaml" 2>/dev/null) || ob_issuer_namespace=""
  ob_state="${TF_VAR_state_directory:?}/openbao"
  ob_manifest="$ob_state/private-state.yaml"
  ob_kubeconfig=$(environment_kubeconfig) || return
}

openbao_kubectl() {
  kubectl --kubeconfig "$ob_kubeconfig" "$@"
}

# Runs one subcommand of the remote script in the OpenBao container. The
# script is the `sh -c` argument, so stdin carries only the data.
openbao_remote() {
  local script
  script=$(cat "$MISE_PROJECT_ROOT/$OPENBAO_REMOTE_SCRIPT") || return
  openbao_kubectl -n "$ob_namespace" exec -i "$OPENBAO_POD" -c "$OPENBAO_CONTAINER" -- sh -c "$script" sh "$@"
}

# Waits until the OpenBao pod is Ready: initialized and unsealed, because its
# readiness probe is `bao status`.
openbao_wait_ready() {
  local seconds="${FIRMAMENT_OPENBAO_SECONDS:-900}"
  if ! openbao_kubectl -n "$ob_namespace" wait --for=create "pod/$OPENBAO_POD" --timeout="${seconds}s" >/dev/null ||
    ! openbao_kubectl -n "$ob_namespace" wait --for=condition=Ready "pod/$OPENBAO_POD" --timeout="${seconds}s" >/dev/null; then
    fail "OpenBao ($ob_namespace/$OPENBAO_POD) was not Ready within ${seconds}s"
  fi
}

# Succeeds when the OpenBao pod exists and is Ready now.
openbao_is_ready() {
  [[ "$(openbao_kubectl -n "$ob_namespace" get pod "$OPENBAO_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}

# SHA-256 of stdin, lowercase hex.
sha256_hex() {
  openssl dgst -sha256 -r | cut -d' ' -f1
}

# Prints the root certificate OpenBao serves publicly.
openbao_live_root() {
  openbao_remote root
}

openbao_live_fingerprint() {
  local root
  root=$(openbao_live_root) || return
  [[ -n "$root" ]] || fail "OpenBao returned an empty root certificate" || return
  printf '%s\n' "$root" | sha256_hex
}

# Prints the fingerprint the manifest records for a snapshot entry
# (snapshot or snapshot_previous), or nothing when there is no entry.
recorded_fingerprint() {
  local entry="${1:-snapshot}"
  [[ -f "$ob_manifest" ]] || return 0
  yq -r ".openbao.$entry.root_fingerprint // \"\"" "$ob_manifest"
}

recorded_path() {
  local entry="${1:-snapshot}"
  [[ -f "$ob_manifest" ]] || return 0
  yq -r ".openbao.$entry.path // \"\"" "$ob_manifest"
}

# Stops when the manifest does not match the private-state contract.
check_manifest_contract() {
  cue vet -c -d '#Contract' "$MISE_PROJECT_ROOT/contracts/private-state/schema.cue" "$1" ||
    fail "$1 does not match the private-state contract"
}
