# shellcheck shell=bash
# Helpers for the tasks that start short-lived pods and check what Hubble
# recorded for them. Source after lib.sh, with $kubeconfig set.
# shellcheck disable=SC2154 # the sourcing task sets kubeconfig

# The image every probe pod runs. It carries wget, which prints response
# headers with -S, and nc, which reports a connection in its exit status. It
# is test infrastructure, so no package or OpenBao setting names it. It is
# the Docker official busybox image mirrored on Amazon ECR Public, not Docker
# Hub, pinned by the digest of the multi-architecture index. The probes run in
# default and the platform namespaces; the signed-image policy would refuse it
# in a tenant namespace.
readonly image=public.ecr.aws/docker/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e

# Runs one short-lived pod, named $2, in namespace $1 and prints what the shell
# command $3 printed. kubectl reads no input: timeout runs it in a process group
# of its own, and a background process that reads the terminal is stopped.
probe() {
  timeout 180 kubectl --kubeconfig "$kubeconfig" -n "$1" run "$2" --rm -i --restart=Never \
    --image="$image" --command -- sh -c "$3" 2>&1 </dev/null || true
}

# A name for the next probe pod, which Hubble keeps in the flows it records.
probe_name() {
  printf 'policy-probe-%s' "$RANDOM"
}

# Fails unless Hubble recorded a flow with verdict $3 from the probe pod
# $1/$2. The rest of the arguments narrow the flows, as hubble observe flags.
# The agent keeps flows in a ring buffer and reports them a moment after the
# probe ends, so the lookup repeats until it finds one or the time is up.
# Hubble prints one flow per line, "Oct 13 10:43:05.854: <from> -> <to> ...";
# the --verdict flag selects the verdict, so the line only has to be a flow.
# A failed exec and any other text, such as an error message, are not a flow.
expect_flow() {
  local namespace="$1" pod="$2" verdict="$3" flows seen
  shift 3
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if flows=$(kubectl --kubeconfig "$kubeconfig" -n kube-system exec ds/cilium -c cilium-agent -- \
      hubble observe --from-pod "$namespace/$pod" --verdict "$verdict" "$@" --since 5m --last 1 2>&1) &&
      grep -Eq '^[A-Z][a-z]{2} [ 0-9]{2} [0-9:.]+: .+ (->|<-|<>) ' <<<"$flows"; then
      return 0
    fi
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

# Prints the address and the listener port of the platform Gateway, separated
# by a space, and fails with a message when it cannot be read or has none yet.
gateway_endpoint() {
  local namespace=kube-system name=platform gateway address port
  gateway=$(kubectl --kubeconfig "$kubeconfig" -n "$namespace" get gateway "$name" -o json) ||
    {
      fail "cannot read the Gateway $namespace/$name"
      return
    }
  address=$(jq -r '.status.addresses[0].value // empty' <<<"$gateway")
  port=$(jq -r '.spec.listeners[0].port // empty' <<<"$gateway")
  [[ -n "$address" && -n "$port" ]] ||
    {
      fail "the Gateway $namespace/$name has no address or listener port yet"
      return
    }
  printf '%s %s\n' "$address" "$port"
}
