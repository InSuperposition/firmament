# shellcheck shell=bash
# Waits for a cluster, a node or a local port to become ready.

# Waits until the node the cluster just created has registered with the API
# server. Retries while k0s starts the API server, whereas kubectl wait fails
# on a node that does not exist yet.
wait_for_node() {
  local kubeconfig="$1" timeout="${2:-300}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout))
  until [[ -n "$(kubectl --kubeconfig "$kubeconfig" get nodes -o name 2>/dev/null)" ]]; do
    if ((SECONDS >= deadline)); then
      fail "no node registered with the API server within ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
}

# Waits until the cluster is healthy after an apply. The first Cilium wait
# retries while k0s restarts the API server, whereas kubectl fails on the
# first refused connection. Then the FluxInstance and the Cilium release
# must be Ready, and Cilium is checked again in case helm-controller rolled
# its pods meanwhile. It does not wait for Flux to apply the pushed commit;
# env:verify does, and cilium:verify then checks the release it deploys.
wait_for_cluster() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$1") || return
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=10m
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready helmrelease/cilium --timeout=10m
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
}

# Waits until something listens on a local TCP port that a background
# process, such as a port-forward, is opening. Fails when that process exits
# first or the port stays closed for the given number of seconds.
wait_for_local_port() {
  local pid="$1" port="$2" timeout="$3"
  local deadline=$((SECONDS + timeout))
  until (: >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "the process that should listen on local port $port exited"
      return 1
    fi
    if ((SECONDS >= deadline)); then
      fail "nothing listens on local port $port after ${timeout}s"
      return 1
    fi
    sleep 0.2
  done
}

# Fails when something already listens on a local TCP port. A port-forward
# to that port would fail, and wait_for_local_port would find the other
# listener and hand its address to the browser.
require_free_local_port() {
  local port="$1"
  if (: >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    fail "local port $port is already in use; pick another with --port"
    return 1
  fi
}
