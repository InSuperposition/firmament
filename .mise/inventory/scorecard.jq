# Joins one environment's inventory to the cluster objects that should back
# it and prints one tab-separated row per namespace: the namespace, its
# tenant, and "pass" or the first failing check with what it found.
#
#   jq -nr --slurpfile inventory inventory.json --slurpfile cluster cluster.json -f scorecard.jq
#
# The cluster file is one kubectl List holding Namespaces, ResourceQuotas,
# CiliumNetworkPolicies, HelmReleases, OCIRepositories and HTTPRoutes. A
# chart's HelmRelease and OCIRepository carry the chart's name, the last
# segment of its source, and live in flux-system.

def flux_namespace: "flux-system";

def object($kind; $namespace; $name):
  [$cluster[0].items[] | select(.kind == $kind and .metadata.namespace == $namespace and .metadata.name == $name)] | first;

def is_true($type):
  ((.status.conditions // []) | map(select(.type == $type)) | first | .status) == "True";

def chart_name: .source | split("/") | last;

# The failure message of one check, or null when it passes.
def namespace_check($name; $entry):
  ([$cluster[0].items[] | select(.kind == "Namespace" and .metadata.name == $name)] | first) as $found
  | if $found == null then "namespace: \($name) does not exist"
    elif $found.metadata.labels["firmament.dev/tenant"] != $entry.tenant then
      "namespace: tenant label is \($found.metadata.labels["firmament.dev/tenant"] // "missing"), the inventory says \($entry.tenant)"
    else null end;

def quota_check($name; $entry):
  object("ResourceQuota"; $name; "tenant") as $found
  | if $found == null then "quota: ResourceQuota tenant is missing"
    elif $found.spec.hard["requests.cpu"] != $entry.quota.cpu or $found.spec.hard["requests.memory"] != $entry.quota.memory then
      "quota: ResourceQuota tenant allows cpu \($found.spec.hard["requests.cpu"]) and memory \($found.spec.hard["requests.memory"]), the inventory says cpu \($entry.quota.cpu) and memory \($entry.quota.memory)"
    else null end;

def policy_check($name):
  if object("CiliumNetworkPolicy"; $name; "platform") == null then "policy: CiliumNetworkPolicy platform is missing" else null end;

def release_check($package):
  ($package | chart_name) as $chart
  | object("HelmRelease"; flux_namespace; $chart) as $found
  | if $found == null then "release: HelmRelease \($chart) is missing"
    elif ($found | is_true("Ready")) | not then "release: HelmRelease \($chart) is not Ready"
    else null end;

def verified_check($package):
  ($package | chart_name) as $chart
  | if $package.signed | not then null
    elif (object("OCIRepository"; flux_namespace; $chart) // {}) | is_true("SourceVerified") | not then
      "chart: OCIRepository \($chart) is not SourceVerified"
    else null end;

def route_check($name; $entry):
  if ([$entry.packages[].ingressPorts | length] | add) == 0 then null
  else
    [$cluster[0].items[] | select(.kind == "HTTPRoute" and .metadata.namespace == $name)] as $routes
    | if ($routes | length) == 0 then "route: no HTTPRoute, but a package lists ingress ports"
      elif ($routes | map(select(([.status.parents[]? | .conditions[]? | select(.type == "Accepted" and .status == "True")] | length) == 0)) | length) > 0 then
        "route: HTTPRoute \($routes | map(select(([.status.parents[]? | .conditions[]? | select(.type == "Accepted" and .status == "True")] | length) == 0)) | first | .metadata.name) is not Accepted"
      else null end
  end;

$inventory[0].namespaces | to_entries[] | .key as $name | .value as $entry
| [
    namespace_check($name; $entry),
    quota_check($name; $entry),
    policy_check($name),
    ($entry.packages[] | release_check(.)),
    ($entry.packages[] | verified_check(.)),
    route_check($name; $entry)
  ]
| map(select(. != null)) | first as $failure
| [$name, $entry.tenant, ($failure // "pass")] | @tsv
