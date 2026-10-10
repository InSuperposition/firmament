#!/usr/bin/env bash
#MISE description="Check that the platform Gateway serves cv: a pod in the default namespace gets HTTP 200 from the Gateway's address, and Hubble recorded the request forwarded into the cv namespace (starts a short-lived pod)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-probe.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-probe.sh"
environment=$(require_environment) || exit
kubeconfig=$(environment_kubeconfig) || exit
cluster=$(cluster_directory) || exit
# The probe image carries wget, which prints the response headers with -S.
image=$(yq -r '.storage.init_image' "$cluster/openbao.yaml") || exit

readonly gateway_namespace=kube-system gateway_name=platform
gateway=$(kubectl --kubeconfig "$kubeconfig" -n "$gateway_namespace" get gateway "$gateway_name" -o json) ||
  fail "cannot read the Gateway $gateway_namespace/$gateway_name" || exit
address=$(jq -r '.status.addresses[0].value // empty' <<<"$gateway")
port=$(jq -r '.spec.listeners[0].port // empty' <<<"$gateway")
[[ -n "$address" && -n "$port" ]] ||
  fail "the Gateway $gateway_namespace/$gateway_name has no address or listener port yet" || exit

pod=$(probe_name)
answer=$(probe default "$pod" "wget -T 8 -S -qO /dev/null http://$address:$port/ 2>&1; echo exit=\$?")
[[ "$answer" == *'HTTP/1.1 200'* && "$answer" == *'exit=0'* ]] ||
  fail "a pod in the default namespace did not get HTTP 200 from http://$address:$port/: $answer" || exit
expect_flow default "$pod" FORWARDED --to-namespace cv || exit
printf 'ok: the Gateway serves cv at http://%s:%s/ (HTTP 200, forwarded into the cv namespace)\n' "$address" "$port"
