# shellcheck shell=bash
# Helpers for the tasks that start short-lived pods and check what Hubble
# recorded for them. Source after lib.sh, with $kubeconfig and $image (a
# container image that carries wget and nc) set.
# shellcheck disable=SC2154 # the sourcing task sets kubeconfig and image

# Runs one short-lived pod, named $2, in namespace $1 and prints what the shell
# command $3 printed.
probe() {
  timeout 180 kubectl --kubeconfig "$kubeconfig" -n "$1" run "$2" --rm -i --restart=Never \
    --image="$image" --command -- sh -c "$3" 2>&1 || true
}

# A name for the next probe pod, which Hubble keeps in the flows it records.
probe_name() {
  printf 'policy-probe-%s' "$RANDOM"
}

# Fails unless Hubble recorded a flow with verdict $3 from the probe pod
# $1/$2. The rest of the arguments narrow the flows, as hubble observe flags.
# The agent keeps flows in a ring buffer and reports them a moment after the
# probe ends, so the lookup repeats until it finds one or the time is up.
expect_flow() {
  local namespace="$1" pod="$2" verdict="$3" flows seen
  shift 3
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    flows=$(kubectl --kubeconfig "$kubeconfig" -n kube-system exec ds/cilium -c cilium-agent -- \
      hubble observe --from-pod "$namespace/$pod" --verdict "$verdict" "$@" --since 5m --last 1 2>&1) || true
    [[ -n "$flows" ]] && return 0
    sleep 2
  done
  seen=$(kubectl --kubeconfig "$kubeconfig" -n kube-system exec ds/cilium -c cilium-agent -- \
    hubble observe --from-pod "$namespace/$pod" --since 5m --last 10 2>&1) || true
  fail "Hubble recorded no $verdict flow from $namespace/$pod ${*:+(filtered by $*)}; it saw:"$'\n'"${seen:-no flows}"
}

# Runs a pod in namespace $1 that tries port $3 of every address in $2 and
# prints exit=0 when any of them accepts the connection, exit=1 when none does.
connect_probe() {
  local pod="$4"
  probe "$1" "$pod" "reached=1; for address in $2; do nc -z -w 8 \$address $3 && reached=0; done; echo exit=\$reached"
}
