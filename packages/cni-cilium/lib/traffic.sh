# shellcheck shell=bash
# Helpers for the traffic probe that cilium:traffic-start deploys and
# cilium:traffic-check reads. Source after .mise/lib.sh.

# Prints where cilium:traffic-start keeps what cilium:traffic-check reads:
# the fortio run, the conn-disrupt restart counts and the Cilium agent pods.
traffic_directory() {
  local state
  state=$(state_directory "$1") || return
  printf '%s/traffic\n' "$state"
}

# Sends one request to the fortio REST API in the traffic-probe client pod
# and prints the reply body. The last argument is the path under /fortio/,
# the ones before it go to `fortio curl`. fortio curl writes the reply
# headers to stderr, so stderr is shown only when the call fails.
fortio_rest() {
  local kubeconfig="$1" errors reply url error_text
  shift
  url="http://localhost:8080/fortio/${*: -1}"
  errors=$(mktemp)
  if ! reply=$(kubectl --kubeconfig "$kubeconfig" -n traffic-probe exec deployment/fortio-client -- \
    fortio curl -quiet -timeout 30s "${@:1:$#-1}" "$url" 2>"$errors"); then
    error_text=$(cat "$errors")
    rm -f "$errors"
    fail "fortio did not answer $url:"$'\n'"$error_text"
    return
  fi
  rm -f "$errors"
  printf '%s\n' "$reply"
}

# Prints the pod identities of the Cilium agents, as workload_identities
# does; two snapshots that differ mean an agent restarted in between.
cilium_agent_identities() {
  workload_identities "$1" <(printf 'kube-system k8s-app=cilium\n')
}

# Prints the state fortio reports for a run: unknown, pending, running,
# stopping or stopped, the number itself for a state fortio does not name,
# or nothing when fortio no longer knows the run.
fortio_run_state() {
  fortio_rest "$1" "rest/status?runid=$2" |
    jq -r --arg run "$2" '.Statuses[$run].State // empty
      | if type == "number" and . >= 0 and . < 5 and . == floor
        then ["unknown", "pending", "running", "stopping", "stopped"][.]
        else tostring end'
}
