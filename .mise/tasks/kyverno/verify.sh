#!/usr/bin/env bash
#MISE description="Check admission in the cluster with server-side dry-run pods, which create nothing: the signed cv image is admitted in cv, an unsigned image and a privileged pod and an ephemeral container are refused there, and an unsigned image is admitted in default; --only runs just the unsigned-image check and prints its result as JSON"
#USAGE flag "--only <guarantee>" help="Run only one guarantee (unsigned-image-refused) and print what it observed as JSON on the last line"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-record.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-record.sh"
require_environment >/dev/null || exit
kubeconfig=$(environment_kubeconfig) || exit

readonly tenant_namespace=cv untouched_namespace=default
# The image the cv release runs, and an image nobody of the tenant signed.
signed_image="ghcr.io/insuperposition/cv@$(yq -r '.image.digest' "$MISE_PROJECT_ROOT/clusters/singularity/values/cv.yaml")"
readonly signed_image unsigned_image=ghcr.io/kyverno/readiness-checker:v1.19.1

# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
only="${usage_only:-}"
case "$only" in
'' | unsigned-image-refused) ;;
*) fail "unknown guarantee '$only'; this task knows unsigned-image-refused" || exit ;;
esac
if [[ -n "$only" ]]; then
  record_begin unsigned-image-refused "mise run kyverno:verify --only $only" \
    "$(jq -nc --arg value "$unsigned_image" '{kind: "tag", value: $value}')"
  trap 'record_end $?' EXIT
fi

# Runs a dry-run pod; prints its output and succeeds when the API server admitted it.
dry_run_pod() {
  local namespace="$1" image="$2" overrides="${3:-{\}}"
  kubectl --kubeconfig "$kubeconfig" -n "$namespace" run admission-probe --image="$image" \
    --dry-run=server --overrides="$overrides" 2>&1
}

[[ -z "$only" ]] || record_step "the signed cv image is admitted in $tenant_namespace"
output=$(dry_run_pod "$tenant_namespace" "$signed_image") ||
  fail "the signed cv image was refused in $tenant_namespace: $output" || exit
[[ -z "$only" ]] || record_pass
[[ -z "$only" ]] || record_step "an unsigned image is refused in $tenant_namespace for its missing signature"
output=$(dry_run_pod "$tenant_namespace" "$unsigned_image") &&
  { fail "an unsigned image was admitted in $tenant_namespace: $output" || exit; }
[[ "$output" == *"must be signed by the signer"* ]] ||
  fail "the unsigned image was refused for another reason: $output" || exit
[[ -z "$only" ]] || record_line refusal "$output"
[[ -z "$only" ]] || record_pass
if [[ -z "$only" ]]; then
  overrides=$(jq -cn --arg image "$signed_image" '{spec: {containers: [{name: "admission-probe", image: $image, securityContext: {privileged: true}}]}}')
  output=$(dry_run_pod "$tenant_namespace" "$signed_image" "$overrides") &&
    { fail "a privileged pod was admitted in $tenant_namespace: $output" || exit; }
  [[ "$output" == *PodSecurity* ]] ||
    fail "the privileged pod was refused for another reason: $output" || exit
  # An ephemeral container is added through the pod's own subresource; the dry
  # run attaches nothing, and an ephemeral container cannot be removed once added.
  pod_json=$(kubectl --kubeconfig "$kubeconfig" -n "$tenant_namespace" get pods -o json | jq '.items[0]') || exit
  pod_name=$(jq -r '.metadata.name // empty' <<<"$pod_json")
  [[ -n "$pod_name" ]] || fail "no pod in $tenant_namespace to attach an ephemeral container to" || exit
  output=$(jq --arg image "$unsigned_image" '.spec.ephemeralContainers = [{name: "admission-probe", image: $image}]' <<<"$pod_json" |
    kubectl --kubeconfig "$kubeconfig" replace --raw "/api/v1/namespaces/$tenant_namespace/pods/$pod_name/ephemeralcontainers?dryRun=All" -f - 2>&1) &&
    { fail "an ephemeral container was admitted in $tenant_namespace: $output" || exit; }
  [[ "$output" == *"ephemeral containers are not allowed"* ]] ||
    fail "the ephemeral container was refused for another reason: $output" || exit
fi
[[ -z "$only" ]] || record_step "an unsigned image is admitted in $untouched_namespace, which the policy leaves alone"
output=$(dry_run_pod "$untouched_namespace" "$unsigned_image") ||
  fail "an unsigned image was refused in $untouched_namespace, which the policy must leave alone: $output" || exit
[[ -z "$only" ]] || record_pass
if [[ -n "$only" ]]; then
  printf 'ok: the signed cv image is admitted and an unsigned image is refused in %s, and %s is untouched\n' "$tenant_namespace" "$untouched_namespace"
  exit 0
fi
printf 'ok: the signed cv image is admitted, an unsigned image and a privileged pod and an ephemeral container are refused in %s, and %s is untouched\n' "$tenant_namespace" "$untouched_namespace"
