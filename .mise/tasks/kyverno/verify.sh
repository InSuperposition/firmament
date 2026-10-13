#!/usr/bin/env bash
#MISE description="Check admission in the cluster with server-side dry-run pods, which create nothing: the signed cv image is admitted in cv, an unsigned image and a privileged pod are refused there, and an unsigned image is admitted in default"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null || exit
kubeconfig=$(environment_kubeconfig) || exit

readonly tenant_namespace=cv untouched_namespace=default
# The image the cv release runs, and an image nobody of the tenant signed.
signed_image="ghcr.io/insuperposition/cv@$(yq -r '.image.digest' "$MISE_PROJECT_ROOT/clusters/singularity/values/cv.yaml")"
readonly signed_image unsigned_image=ghcr.io/kyverno/readiness-checker:v1.19.1

# Runs a dry-run pod; prints its output and succeeds when the API server admitted it.
dry_run_pod() {
  local namespace="$1" image="$2" overrides="${3:-{\}}"
  kubectl --kubeconfig "$kubeconfig" -n "$namespace" run admission-probe --image="$image" \
    --dry-run=server --overrides="$overrides" 2>&1
}

output=$(dry_run_pod "$tenant_namespace" "$signed_image") ||
  fail "the signed cv image was refused in $tenant_namespace: $output" || exit
output=$(dry_run_pod "$tenant_namespace" "$unsigned_image") &&
  { fail "an unsigned image was admitted in $tenant_namespace: $output" || exit; }
[[ "$output" == *"must be signed by the signer"* ]] ||
  fail "the unsigned image was refused for another reason: $output" || exit
overrides=$(jq -cn --arg image "$signed_image" '{spec: {containers: [{name: "admission-probe", image: $image, securityContext: {privileged: true}}]}}')
output=$(dry_run_pod "$tenant_namespace" "$signed_image" "$overrides") &&
  { fail "a privileged pod was admitted in $tenant_namespace: $output" || exit; }
[[ "$output" == *PodSecurity* ]] ||
  fail "the privileged pod was refused for another reason: $output" || exit
output=$(dry_run_pod "$untouched_namespace" "$unsigned_image") ||
  fail "an unsigned image was refused in $untouched_namespace, which the policy must leave alone: $output" || exit
printf 'ok: the signed cv image is admitted, an unsigned image and a privileged pod are refused in %s, and %s is untouched\n' "$tenant_namespace" "$untouched_namespace"
