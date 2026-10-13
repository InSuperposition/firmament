#!/usr/bin/env bash
#MISE description="Check that each tenant namespace's installer account can act in its own namespace and nowhere else: it may create deployments there, and may not create cluster roles, cluster role bindings, namespaces or deployments in kube-system (read-only: asks the API server with can-i)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
environment=$(require_environment) || exit
kubeconfig=$(environment_kubeconfig) || exit

# The installer accounts come from the same resolution that rendered them.
installers=$(cd "$MISE_PROJECT_ROOT" && cue export .:inputs -e "installers.\"$environment\"" --out json |
  jq -r 'to_entries[] | [.key, .value] | @tsv') || exit
if [[ -z "$installers" ]]; then
  printf 'ok: environment %s has no tenant installer account\n' "$environment"
  exit 0
fi

# Prints the answer to one can-i question as the installer account.
can_i() {
  local account="$1"
  shift
  kubectl --kubeconfig "$kubeconfig" auth can-i "$@" --as="system:serviceaccount:flux-system:$account" 2>/dev/null || true
}

while IFS=$'\t' read -r namespace account; do
  [[ "$(can_i "$account" create deployments -n "$namespace")" == yes ]] ||
    fail "the installer $account cannot create deployments in $namespace, its own namespace" || exit
  for denied in "clusterroles" "clusterrolebindings" "namespaces" "deployments -n kube-system"; do
    # shellcheck disable=SC2086 # the resource and its flags are separate words
    [[ "$(can_i "$account" create $denied)" == no ]] ||
      fail "the installer $account can create $denied, which is outside $namespace" || exit
  done
  printf 'ok: the installer %s acts in %s and nowhere else\n' "$account" "$namespace"
done <<<"$installers"
