#!/usr/bin/env bash
#MISE description="Check that every retired binding's chart objects and workloads are gone: lists the HelmRelease, source, values and workloads a retirement left behind (read-only)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
environment=$(require_environment) || exit
kubeconfig=$(environment_kubeconfig) || exit

retired=$(cd "$MISE_PROJECT_ROOT" && cue export .:inputs -e "retired.\"$environment\"" --out json |
  jq -r '.[] | [.package, .namespace] | @tsv') || exit
if [[ -z "$retired" ]]; then
  printf 'ok: environment %s retires no binding\n' "$environment"
  exit 0
fi

# Pruning is disabled on the chart objects, so retiring a binding leaves them
# running until an explicit teardown removes them.
chart_objects=$(kubectl --kubeconfig "$kubeconfig" -n flux-system get \
  helmreleases.helm.toolkit.fluxcd.io,ocirepositories.source.toolkit.fluxcd.io,configmaps -o name) ||
  fail "cannot list the chart objects in flux-system" || exit

remaining=()
while IFS=$'\t' read -r package namespace; do
  for object in "$package" "$package-values"; do
    while IFS= read -r found; do
      [[ -n "$found" ]] && remaining+=("$found (flux-system) of retired $package")
    done < <(grep -E "^[^/]+/$object\$" <<<"$chart_objects" || true)
  done
  workloads=$(kubectl --kubeconfig "$kubeconfig" -n "$namespace" get deployments,statefulsets,daemonsets \
    -l "helm.toolkit.fluxcd.io/name=$package" -o name) ||
    fail "cannot list the workloads of $package in $namespace" || exit
  while IFS= read -r found; do
    [[ -n "$found" ]] && remaining+=("$found ($namespace) of retired $package")
  done <<<"$workloads"
done <<<"$retired"

if ((${#remaining[@]})); then
  printf 'still present after retirement:\n' >&2
  printf '  %s\n' "${remaining[@]}" >&2
  exit 1
fi
printf 'ok: every retired binding of %s is torn down\n' "$environment"
