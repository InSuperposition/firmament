#!/usr/bin/env bash
#MISE description="Check the network policy on the cluster, each probe against the verdict Hubble recorded for it: a pod in the namespace of a package that requires secrets reaches OpenBao, and a pod in a namespace nothing allows does not; a pod in the default namespace resolves names but cannot reach a port of an ingress-denied platform namespace, nor a tenant namespace; a tenant pod cannot reach the API server (starts short-lived pods)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
environment=$(require_environment) || exit
kubeconfig=$(environment_kubeconfig) || exit
cluster=$(cluster_directory) || exit

# The provider and the first consumer come from the same resolution that
# rendered the policies, so this checks what was rendered.
policy=$(cd "$MISE_PROJECT_ROOT" && cue export .:inputs -e "policy.$environment" --out json) ||
  fail "cannot resolve the network policy of environment $environment" || exit
provider=$(jq -r '[.namespaces | to_entries[] | select(any(.value.provides[]; (.consumers | length) > 0))] | first | .key // empty' <<<"$policy")
[[ -n "$provider" ]] || fail "no namespace provides a capability that another namespace requires; nothing to check" || exit
consumer=$(jq -r --arg ns "$provider" '.namespaces[$ns].provides[0].consumers[0]' <<<"$policy")
service_port=$(yq -r '.server.service.port' "$cluster/values/openbao.yaml") || exit
image=$(yq -r '.storage.init_image' "$cluster/openbao.yaml") || exit
url="https://openbao.$provider.svc:$service_port/v1/sys/health"

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

pod=$(probe_name)
allowed=$(probe "$consumer" "$pod" "wget -T 8 -qO- --no-check-certificate '$url'; echo exit=\$?")
if [[ "$allowed" != *'"initialized":true'* ]]; then
  fail "a pod in $consumer, which requires secrets, did not reach OpenBao at $url: $allowed" || exit
fi
expect_flow "$consumer" "$pod" FORWARDED --to-namespace "$provider" || exit
pod=$(probe_name)
denied=$(probe default "$pod" "wget -T 8 -qO- --no-check-certificate '$url'; echo exit=\$?")
if [[ "$denied" == *'"initialized"'* ]]; then
  fail "a pod in the default namespace reached OpenBao at $url, which nothing allows" || exit
fi
if [[ "$denied" != *'exit=1'* ]]; then
  fail "the pod in the default namespace failed for another reason than a blocked connection: $denied" || exit
fi
expect_flow default "$pod" DROPPED --to-namespace "$provider" || exit
printf 'ok: %s reaches OpenBao in %s; default does not\n' "$consumer" "$provider"

# The platform namespaces that deny ingress only: every pod may use DNS and
# nothing else of theirs is reachable without an allow.
platform=$(jq -r '[.namespaces | to_entries[] | select(.value.mode == "ingress")] | first | .key // empty' <<<"$policy")
if [[ -n "$platform" ]]; then
  pod=$(probe_name)
  resolved=$(probe default "$pod" "nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; echo exit=\$?")
  [[ "$resolved" == *'exit=0'* ]] || fail "a pod in the default namespace could not resolve a name: $resolved" || exit
  expect_flow default "$pod" FORWARDED --to-port 53 || exit
  # A pod-network pod of the namespace, and a port no allow names (the
  # kubelet's probes reach other ports; this one is Hubble relay's server).
  target=$(kubectl --kubeconfig "$kubeconfig" -n "$platform" get pods -l k8s-app=hubble-relay -o json |
    jq -r '[.items[] | select(.status.podIP != .status.hostIP) | .status.podIP] | first // empty')
  [[ -n "$target" ]] || fail "no pod-network pod labelled k8s-app=hubble-relay in $platform to probe" || exit
  pod=$(probe_name)
  blocked=$(probe default "$pod" "wget -T 8 -qO- http://$target:4245/; echo exit=\$?")
  [[ "$blocked" == *'timed out'* ]] || fail "a pod in the default namespace was not blocked from $platform ($target:4245): $blocked" || exit
  expect_flow default "$pod" DROPPED --to-ip "$target" --to-port 4245 || exit
  printf 'ok: default resolves names and is blocked from the %s pod %s\n' "$platform" "$target"
fi

# The namespaces of a tenant that is not the platform tenant: ingress is
# denied by the clusterwide policy, and no allow opens the API server to them.
tenant=$(jq -r '[.namespaces | to_entries[] | select(.value.mode == "allow" and (.value.hostPorts | length) > 0)] | first | .key // empty' <<<"$policy")
if [[ -n "$tenant" ]]; then
  port=$(jq -r --arg ns "$tenant" '.namespaces[$ns].hostPorts[0].port' <<<"$policy")
  target=$(kubectl --kubeconfig "$kubeconfig" -n "$tenant" get pods -o json |
    jq -r '[.items[] | select(.status.podIP != .status.hostIP) | .status.podIP] | first // empty')
  [[ -n "$target" ]] || fail "no pod-network pod in $tenant to probe" || exit
  pod=$(probe_name)
  blocked=$(probe default "$pod" "wget -T 8 -qO- http://$target:$port/; echo exit=\$?")
  [[ "$blocked" == *'timed out'* ]] || fail "a pod in the default namespace was not blocked from $tenant ($target:$port): $blocked" || exit
  expect_flow default "$pod" DROPPED --to-ip "$target" --to-port "$port" || exit
  printf 'ok: default is blocked from the %s pod %s on port %s\n' "$tenant" "$target" "$port"
  pod=$(probe_name)
  api=$(probe "$tenant" "$pod" "wget -T 8 -qO- --no-check-certificate https://kubernetes.default.svc/version; echo exit=\$?")
  [[ "$api" == *'timed out'* ]] || fail "a pod in $tenant was not blocked from the API server: $api" || exit
  expect_flow "$tenant" "$pod" DROPPED || exit
  printf 'ok: a pod in %s cannot reach the API server\n' "$tenant"
fi
