#!/usr/bin/env bash
#MISE description="Check two tenant guarantees on the cluster: Flux refuses a chart whose signer is wrong and a chart with no signature (for each chart source that must be signed, a copy with the real check verifies, a copy that demands another signer does not, and a copy pointed at an unsigned chart does not), and a namespace that no binding names stays denied (creates and deletes temporary chart sources in flux-system and a temporary namespace with one pod)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck source=../../lib-probe.sh
source "${MISE_PROJECT_ROOT}/.mise/lib-probe.sh"
require_environment >/dev/null
kubeconfig=$(environment_kubeconfig) || exit
cluster=$(cluster_directory) || exit
# The probe image carries nc, which opens a connection and reports it in its exit status.
image=$(yq -r '.storage.init_image' "$cluster/openbao.yaml") || exit

readonly flux_namespace=flux-system
readonly marker=firmament.test/tenant-verify
readonly wrong_subject='^https://github\.com/firmament-test/never-signs/\.github/workflows/none\.yaml@refs/heads/main$'
fixture="$MISE_PROJECT_ROOT/.mise/tenant/unsigned-chart.yaml"
unsigned_source=$(yq -r '.source' "$fixture") || exit
unsigned_digest=$(yq -r '.digest' "$fixture") || exit

flux_kubectl() {
  kubectl --kubeconfig "$kubeconfig" -n "$flux_namespace" "$@"
}

# Removes every temporary source and namespace, this run's and a crashed run's.
remove_temporary_objects() {
  flux_kubectl delete ocirepositories.source.toolkit.fluxcd.io -l "$marker" --ignore-not-found --wait=false >/dev/null || true
  kubectl --kubeconfig "$kubeconfig" delete namespaces -l "$marker" --ignore-not-found --wait=false >/dev/null || true
}
trap remove_temporary_objects EXIT
remove_temporary_objects

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
[[ -n "$sources" ]] || fail "no chart source in $flux_namespace must be signed; nothing to check" || exit

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

# A namespace that no binding names is denied by the clusterwide policy, as a
# namespace is whose binding was removed: the policy selects by exclusion from
# the platform namespaces, so binding history does not matter. A pod in it
# listens on a port; a pod in the default namespace must not reach it.
retained="test-retained-$RANDOM"
port=8080
kubectl --kubeconfig "$kubeconfig" create namespace "$retained" >/dev/null || exit
kubectl --kubeconfig "$kubeconfig" label namespace "$retained" "$marker=true" >/dev/null || exit
kubectl --kubeconfig "$kubeconfig" -n "$retained" run holder --restart=Never --image="$image" \
  --command -- sh -c "while true; do nc -l -p $port; done" >/dev/null || exit
kubectl --kubeconfig "$kubeconfig" -n "$retained" wait --for=condition=Ready pod/holder --timeout=180s >/dev/null || exit
address=$(kubectl --kubeconfig "$kubeconfig" -n "$retained" get pod holder -o jsonpath='{.status.podIP}') || exit
# The pod does listen, so a failed connection below is the policy's doing.
listening=$(kubectl --kubeconfig "$kubeconfig" -n "$retained" exec holder -- sh -c "nc -z -w 2 127.0.0.1 $port; echo exit=\$?" 2>&1) || true
[[ "$listening" == *'exit=0'* ]] || fail "the pod in $retained does not listen on port $port: $listening" || exit
pod=$(probe_name)
blocked=$(connect_probe default "$address" "$port" "$pod")
if [[ "$blocked" == *'exit=0'* ]]; then
  fail "a pod in the default namespace reached port $port of $retained, a namespace no binding names" || exit
fi
if [[ "$blocked" != *'exit=1'* ]]; then
  fail "the pod in the default namespace failed for another reason than a blocked connection: $blocked" || exit
fi
expect_flow default "$pod" DROPPED --to-ip "$address" --to-port "$port" || exit
printf 'ok: a namespace no binding names stays denied: default cannot reach port %s of %s\n' "$port" "$retained"
