#!/usr/bin/env bash
#MISE description="Check that Flux refuses a chart whose signer is wrong and a chart with no signature: for each chart source that must be signed, a copy with the real signature check still verifies, a copy that demands another signer does not, and a copy pointed at an unsigned chart does not (creates and deletes temporary chart sources in flux-system)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null
kubeconfig=$(environment_kubeconfig) || exit

readonly namespace=flux-system
readonly marker=firmament.test/tenant-verify
readonly wrong_subject='^https://github\.com/firmament-test/never-signs/\.github/workflows/none\.yaml@refs/heads/main$'
fixture="$MISE_PROJECT_ROOT/.mise/tenant/unsigned-chart.yaml"
unsigned_source=$(yq -r '.source' "$fixture") || exit
unsigned_digest=$(yq -r '.digest' "$fixture") || exit

flux_kubectl() {
  kubectl --kubeconfig "$kubeconfig" -n "$namespace" "$@"
}

# Removes every temporary source, this run's and a crashed run's.
remove_temporary_sources() {
  flux_kubectl delete ocirepositories.source.toolkit.fluxcd.io -l "$marker" --ignore-not-found --wait=false >/dev/null || true
}
trap remove_temporary_sources EXIT
remove_temporary_sources

# Creates a temporary copy of the live source $1 under the name $2. The jq
# program $3 edits the copy's spec; the arguments after it are jq options
# that define the variables it uses.
create_copy() {
  local original="$1" name="$2" edit="$3"
  shift 3
  flux_kubectl get ocirepositories.source.toolkit.fluxcd.io "$original" -o json |
    jq "$@" --arg name "$name" --arg marker "$marker" "{apiVersion, kind, metadata: {name: \$name, namespace: .metadata.namespace, labels: {(\$marker): \"true\"}}, spec: (.spec | $edit)}" |
    flux_kubectl apply -f - >/dev/null
}

# Fails unless the source $1 gets its SourceVerified condition with status $2.
expect_verified() {
  local name="$1" status="$2"
  flux_kubectl wait --for=create "ocirepositories.source.toolkit.fluxcd.io/$name" --timeout=60s >/dev/null || return
  if ! flux_kubectl wait "--for=condition=SourceVerified=$status" "ocirepositories.source.toolkit.fluxcd.io/$name" --timeout=180s >/dev/null; then
    fail "source $name never had SourceVerified=$status; its conditions:"$'\n'"$(flux_kubectl get ocirepositories.source.toolkit.fluxcd.io "$name" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}')"
  fi
}

sources=$(flux_kubectl get ocirepositories.source.toolkit.fluxcd.io -l "!$marker" -o json |
  jq -r '.items[] | select(.spec.verify != null) | .metadata.name') || exit
[[ -n "$sources" ]] || fail "no chart source in $namespace must be signed; nothing to check" || exit

# shellcheck disable=SC2016 # the jq programs name jq variables, not shell ones
while IFS= read -r original; do
  suffix=$RANDOM
  control="test-control-$suffix"
  wrong="test-wrong-signer-$suffix"
  unsigned="test-unsigned-$suffix"
  # The control keeps the real check, so a refusal below cannot be a
  # registry or network fault.
  create_copy "$original" "$control" '.' || exit
  expect_verified "$control" True || exit
  create_copy "$original" "$wrong" '.verify.matchOIDCIdentity[0].subject = $subject' --arg subject "$wrong_subject" || exit
  expect_verified "$wrong" False || exit
  create_copy "$original" "$unsigned" '.url = $source | .ref.digest = $digest' --arg source "$unsigned_source" --arg digest "$unsigned_digest" || exit
  expect_verified "$unsigned" False || exit
  printf 'ok: Flux verifies %s, refuses it when another signer is required, and refuses an unsigned chart under the same check\n' "$original"
done <<<"$sources"
