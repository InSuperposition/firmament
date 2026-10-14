#!/usr/bin/env bash
#MISE description="Check the network policy on the cluster, each probe against the verdict Hubble recorded for it: every consumer of a capability reaches its provider's port, and a pod in the default namespace does not; a pod in the default namespace resolves names but cannot reach a port of an ingress-denied platform namespace, nor a tenant namespace; the policies leave a tenant pod no egress to the API server (reads the policies; starts short-lived pods in default)"
#USAGE flag "--only <guarantee>" help="Run only one guarantee (direct-access-denied-gateway-allowed) and print what it observed as JSON on the last line"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-probe.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-probe.sh"
# shellcheck source=../../lib-record.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-record.sh"
environment=$(require_environment) || exit
kubeconfig=$(environment_kubeconfig) || exit

# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
only="${usage_only:-}"
case "$only" in
'' | direct-access-denied-gateway-allowed) ;;
*) fail "unknown guarantee '$only'; this task knows direct-access-denied-gateway-allowed" || exit ;;
esac

# The providers and their consumers come from the same resolution that
# rendered the policies, so this checks what was rendered.
policy=$(cd "$MISE_PROJECT_ROOT" && cue export .:inputs -e "policy.$environment" --out json) ||
  fail "cannot resolve the network policy of environment $environment" || exit
# One line per allowed edge: provider namespace, port, consumer namespace.
edges=""
[[ -n "$only" ]] || edges=$(jq -r '.namespaces | to_entries[] | .key as $provider | .value.provides[]? | .port as $port | .consumers[]? | [$provider, $port, .] | @tsv' <<<"$policy")
[[ -n "$only" || -n "$edges" ]] || fail "no namespace provides a capability that another namespace requires; nothing to check" || exit

# Prints the pod-network pod IPs of a namespace, one per line.
pod_addresses() {
  kubectl --kubeconfig "$kubeconfig" -n "$1" get pods -o json |
    jq -r '.items[] | select(.status.podIP != .status.hostIP) | .status.podIP'
}

# Fails unless a pod in default is blocked from a pod-network pod of the tenant
# namespace $1 on its first host port, with a Hubble drop.
expect_default_blocked_from() {
  local tenant="$1" port target pod blocked
  port=$(jq -r --arg ns "$tenant" '.namespaces[$ns].hostPorts[0].port' <<<"$policy")
  target=$(kubectl --kubeconfig "$kubeconfig" -n "$tenant" get pods -o json |
    jq -r '[.items[] | select(.status.podIP != .status.hostIP) | .status.podIP] | first // empty')
  [[ -n "$target" ]] || fail "no pod-network pod in $tenant to probe" || exit
  pod=$(probe_name)
  blocked=$(probe default "$pod" "wget -T 8 -qO- http://$target:$port/; echo exit=\$?")
  [[ "$blocked" == *'timed out'* ]] || fail "a pod in the default namespace was not blocked from $tenant ($target:$port): $blocked" || exit
  expect_flow default "$pod" DROPPED --to-ip "$target" --to-port "$port" || exit
  printf 'ok: default is blocked from the %s pod %s on port %s\n' "$tenant" "$target" "$port"
}

# --only direct-access-denied-gateway-allowed: the cv pod cannot be reached
# directly from default, and the Gateway still serves cv to a pod there.
if [[ -n "$only" ]]; then
  jq -e '.namespaces.cv.hostPorts[0].port' <<<"$policy" >/dev/null ||
    fail "the network policy of environment $environment has no host port for the namespace cv; nothing to check" || exit
  record_begin direct-access-denied-gateway-allowed "mise run network-policy:verify --only $only"
  trap 'record_end $?' EXIT
  record_step "a pod in default is blocked from the cv pod, with a Hubble drop"
  expect_default_blocked_from cv
  record_flow DROPPED 1 300
  record_pass
  record_step "the Gateway serves cv to a pod in default"
  gateway_output=$(usage_result=true "$MISE_PROJECT_ROOT/.mise/tasks/gateway/verify.sh") ||
    fail "the Gateway check failed: $gateway_output" || exit
  sed '$d' <<<"$gateway_output"
  record_merge "$(tail -n 1 <<<"$gateway_output" | jq -c .observations)"
  record_pass
  exit 0
fi

while IFS=$'\t' read -r provider port consumer; do
  addresses=$(pod_addresses "$provider" | paste -sd' ' -)
  [[ -n "$addresses" ]] || fail "no pod-network pod in $provider to probe" || exit
  pod=$(probe_name)
  allowed=$(connect_probe "$consumer" "$addresses" "$port" "$pod")
  if [[ "$allowed" != *'exit=0'* ]]; then
    fail "a pod in $consumer, which requires a capability of $provider, did not reach port $port of $provider: $allowed" || exit
  fi
  expect_flow "$consumer" "$pod" FORWARDED --to-namespace "$provider" || exit
  printf 'ok: %s reaches port %s of %s\n' "$consumer" "$port" "$provider"
done <<<"$edges"

# Nothing but a consumer may reach a provider's port: the default namespace is
# in nobody's list.
while IFS=$'\t' read -r provider port; do
  addresses=$(pod_addresses "$provider" | paste -sd' ' -)
  pod=$(probe_name)
  denied=$(connect_probe default "$addresses" "$port" "$pod")
  if [[ "$denied" == *'exit=0'* ]]; then
    fail "a pod in the default namespace reached port $port of $provider, which nothing allows" || exit
  fi
  if [[ "$denied" != *'exit=1'* ]]; then
    fail "the pod in the default namespace failed for another reason than a blocked connection: $denied" || exit
  fi
  expect_flow default "$pod" DROPPED --to-namespace "$provider" || exit
  printf 'ok: default does not reach port %s of %s\n' "$port" "$provider"
done < <(cut -f1,2 <<<"$edges" | sort -u)

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
  expect_default_blocked_from "$tenant"
  # The signed-image policy refuses an unsigned probe pod in a tenant
  # namespace, and an ephemeral container is refused there too, so the API
  # server's denial is read from the policies instead: the clusterwide deny
  # covers the namespace, keeps egress off, and opens DNS only, and the
  # namespace's own policy opens no entity.
  deny=$(kubectl --kubeconfig "$kubeconfig" get ciliumclusterwidenetworkpolicies.cilium.io tenant-default-deny -o json) ||
    fail "cannot read the clusterwide policy tenant-default-deny" || exit
  jq -e --arg ns "$tenant" '
    .spec.enableDefaultDeny.egress == true
    and ([.spec.endpointSelector.matchExpressions[] | select(.operator == "NotIn") | .values[]] | index($ns) | not)
    and ([.spec.egress[] | (.toEntities // [])[]] | length == 0)' <<<"$deny" >/dev/null ||
    fail "the clusterwide policy tenant-default-deny does not deny egress from $tenant to everything but DNS" || exit
  allowed=$(kubectl --kubeconfig "$kubeconfig" -n "$tenant" get ciliumnetworkpolicies.cilium.io platform -o json) ||
    fail "cannot read the policy of $tenant" || exit
  jq -e '[(.spec.egress // [])[] | (.toEntities // [])[]] | length == 0' <<<"$allowed" >/dev/null ||
    fail "the policy of $tenant allows egress to an entity, which includes the API server: $(jq -c '.spec.egress' <<<"$allowed")" || exit
  printf 'ok: the policies leave a pod in %s no egress to the API server\n' "$tenant"
fi
