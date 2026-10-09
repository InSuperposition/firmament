#!/usr/bin/env bash
#MISE description="Check the network policy on the cluster: a pod in the namespace of a package that requires secrets reaches OpenBao, and a pod in a namespace nothing allows does not (starts two short-lived pods)"
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

# Runs one short-lived pod in a namespace and prints what the request printed.
probe() {
  timeout 180 kubectl --kubeconfig "$kubeconfig" -n "$1" run "policy-probe-$RANDOM" --rm -i --restart=Never \
    --image="$image" --command -- sh -c "wget -T 8 -qO- --no-check-certificate '$url'; echo exit=\$?" 2>&1 || true
}

allowed=$(probe "$consumer")
if [[ "$allowed" != *'"initialized":true'* ]]; then
  fail "a pod in $consumer, which requires secrets, did not reach OpenBao at $url: $allowed" || exit
fi
denied=$(probe default)
if [[ "$denied" == *'"initialized"'* ]]; then
  fail "a pod in the default namespace reached OpenBao at $url, which nothing allows" || exit
fi
if [[ "$denied" != *'exit=1'* ]]; then
  fail "the pod in the default namespace failed for another reason than a blocked connection: $denied" || exit
fi
printf 'ok: %s reaches OpenBao in %s; default does not\n' "$consumer" "$provider"
