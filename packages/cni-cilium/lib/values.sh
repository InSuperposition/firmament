# shellcheck shell=bash
# Checks that the deployed cilium release runs the values Flux applied.
# Source after .mise/lib.sh.

# Prints the YAML values on stdin as one line of JSON with sorted keys, so
# two documents holding the same values print the same text.
canonical_values() {
  yq -o=json -I=0 'sort_keys(..)'
}

# Succeeds when the deployed cilium release runs the values in the
# cilium-values ConfigMap, as Flux last applied it. A HelmRelease reports
# Ready for its previous values until helm-controller notices the change.
cilium_values_deployed() {
  local kubeconfig="$1" wanted deployed
  wanted=$(kubectl --kubeconfig "$kubeconfig" -n flux-system get configmap cilium-values \
    -o jsonpath='{.data.values\.yaml}' | canonical_values) || return
  deployed=$(helm --kubeconfig "$kubeconfig" -n kube-system get values cilium -o yaml | canonical_values) || return
  [[ -n "$wanted" && "$wanted" != null && "$wanted" == "$deployed" ]]
}

# Waits until the cilium release runs the values Flux applied.
wait_for_cilium_values() {
  local kubeconfig="$1" timeout="${2:-600}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout))
  until cilium_values_deployed "$kubeconfig" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      fail "the cilium release does not run the values in the cilium-values ConfigMap after ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
}
