#!/usr/bin/env bash
#MISE description="Print one row per inventory namespace, pass or the first failing check (namespace tenant label, ResourceQuota, network policy, HelmRelease Ready, chart signature verified, route Accepted), and fail when any row fails; reads the cluster, changes nothing"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
require_environment >/dev/null
kubeconfig=$(environment_kubeconfig) || exit

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export_inventory >"$work/inventory.json" || exit
# One list call: every check reads the same moment of the cluster.
kubectl --kubeconfig "$kubeconfig" get \
  namespaces,resourcequotas,ciliumnetworkpolicies.cilium.io,helmreleases.helm.toolkit.fluxcd.io,ocirepositories.source.toolkit.fluxcd.io,httproutes.gateway.networking.k8s.io \
  -A -o json >"$work/cluster.json" || fail "cannot read the cluster" || exit

jq -nr --slurpfile inventory "$work/inventory.json" --slurpfile cluster "$work/cluster.json" \
  -f "$MISE_PROJECT_ROOT/.mise/inventory/scorecard.jq" >"$work/rows.tsv" || exit
{
  printf 'NAMESPACE\tTENANT\tRESULT\n'
  cat "$work/rows.tsv"
} | column -t -s $'\t'
if awk -F '\t' '$3 != "pass" { found = 1 } END { exit !found }' "$work/rows.tsv"; then
  fail "the scorecard has failing rows" || exit
fi
