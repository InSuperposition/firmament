#!/usr/bin/env bats

# Each test renders a private copy of the data files and the render code, so
# a planted fault never touches the working tree.

setup() {
  root_directory="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  work="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$work"
  cp -R "$root_directory"/{cue.mod,inputs.cue,render,contracts,packages,clusters,environments} "$work"
  mkdir -p "$work/.mise/tasks"
  cp "$root_directory/.mise/tasks/render.sh" "$work/.mise/tasks"
  rm -rf "$work/clusters/singularity/rendered"
  cd "$work"
}

render_all() {
  MISE_PROJECT_ROOT="$work" "$work/.mise/tasks/render.sh"
}

# A second environment on the same cluster, whose platform tenant has half the CPU.
declare_stage_environment() {
  cp -R environments/local environments/stage
  yq -i '.namespace_quota.cpu = "8"' environments/stage/tenants/platform.yaml
}

render() {
  ENVIRONMENT="${1:-local}" timoni bundle build -f render/bundle.cue --runtime-from-env --output-dir "$2"
}

# Binds a tenant package `site` to the namespace shop: it lists host port 44100
# and requires secrets.
bind_site() {
  mkdir -p packages/site
  cat >packages/site/package.yaml <<'YAML'
name: site
layer: app
pin:
  source: oci://ghcr.io/example/charts/site
  version: 1.0.0
  digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
requires:
  - capability: secrets
    scope: cluster
host_ports:
  - port: 44100
    protocol: TCP
YAML
  printf '{}\n' >clusters/singularity/values/site.yaml
  printf -- '- package: site\n  namespace: shop\n  tenant: apps\n' >>clusters/singularity/packages.yaml
}

@test "the data files pass cue vet -c" {
  run cue vet -c .:inputs
  [ "$status" -eq 0 ]
}

@test "a binding without a tenant is refused, naming the field" {
  printf -- '- package: cilium\n  namespace: shop\n' >>clusters/singularity/packages.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *tenant* ]]
}

@test "a binding to a tenant the environment does not define is refused, naming it" {
  printf -- '- package: cilium\n  namespace: shop\n  tenant: ghost\n' >>clusters/singularity/packages.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *ghost* ]]
}

@test "a binding to a package that does not exist is refused, naming it" {
  printf -- '- package: ghost\n  namespace: shop\n  tenant: platform\n' >>clusters/singularity/packages.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *ghost* ]]
}

@test "a package.yaml whose name differs from its folder is refused, naming both" {
  sed -i.bak 's/^name: flux$/name: fluxx/' packages/flux/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *fluxx* ]]
}

@test "a package.yaml pin equals the chart the bootstrap installs" {
  for package in cilium flux; do
    digest=$(yq -r '.pin.digest' "packages/$package/package.yaml")
    [ "$digest" = "$(yq -r '.spec.ref.digest' "packages/$package/ocirepository.yaml")" ]
  done
}

@test "a chart package whose pin names a tag instead of a digest is refused, naming the field" {
  sed -i.bak 's/^  digest: .*/  digest: v1.21.2/' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *digest* ]]
}

@test "a chart package without a pin is refused, naming the field" {
  sed -i.bak '/^pin:/,/^  digest:/d' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *pin* ]]
}

@test "a bound chart package without a values file is refused, naming the package" {
  # Another values file keeps the glob from matching nothing.
  mv clusters/singularity/values/cert-manager.yaml clusters/singularity/values/other.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *cert-manager* ]]
}

@test "OpenBao's generated config equals its golden file" {
  cue export .:inputs -e charts.local.openbao.values.server.ha.raft.config --out text >"$BATS_TEST_TMPDIR/openbao.hcl"
  diff "$root_directory/packages/openbao/config/testdata/openbao.hcl" "$BATS_TEST_TMPDIR/openbao.hcl"
}

@test "an OpenBao role that does not decide require_cn is refused, naming the field" {
  yq -i 'del(.pki.roles."cluster-leaf".require_cn)' clusters/singularity/openbao.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *require_cn* ]]
}

@test "an OpenBao role with an unsupported key_type is refused, naming the field" {
  yq -i '.pki.roles."cluster-leaf".key_type = "dsa"' clusters/singularity/openbao.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *key_type* ]]
}

@test "a Kubernetes role that names an undeclared policy is refused, naming the policy" {
  yq -i '.kubernetes.roles."cert-manager".policies = ["ghost"]' clusters/singularity/openbao.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *ghost* ]]
}

@test "an OpenBao data section the schema does not declare is refused, naming it" {
  yq -i '.audit = {"type": "file"}' clusters/singularity/openbao.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *audit* ]]
}

@test "a values file that sets the key the OpenBao generator sets is refused, naming it" {
  yq -i '.server.ha.raft.config = "ui = true"' clusters/singularity/values/openbao.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *config* ]]
}

@test "OpenBao installs through the chart module, in its own namespace, with the config in its values" {
  render local "$BATS_TEST_TMPDIR/out"
  release="$BATS_TEST_TMPDIR/out/openbao/helm.toolkit.fluxcd.io_v2_helmrelease_openbao.yaml"
  [ "$(yq -r '.spec.targetNamespace' "$release")" = openbao ]
  grep -q 'tls_acme_domains *= \["openbao.openbao.svc"\]' "$BATS_TEST_TMPDIR/out/openbao/v1_configmap_openbao-values.yaml"
  [ -e "$BATS_TEST_TMPDIR/out/namespace/v1_namespace_openbao.yaml" ]
}

@test "OpenBao's data-owner init container runs as root although the pod does not" {
  run cue export .:inputs -e 'charts.local.openbao.values.server.extraInitContainers[0].securityContext' --out json
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"runAsUser":0,"runAsNonRoot":false}' ]
}

@test "a requirement no package provides is refused, naming the package and the capability" {
  yq -i '.requires[0].capability = "ghostcap"' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *cert-manager* ]]
  [[ "$output" == *ghostcap* ]]
}

@test "a host port outside 1 to 65535 or with an unknown protocol is refused, naming the field" {
  yq -i '.host_ports[0].port = 70000' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *port* ]]
  yq -i '.host_ports[0].port = 9403 | .host_ports[0].protocol = "ICMP"' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *protocol* ]]
}

@test "each trust namespace gets one policy with both an ingress and an egress section" {
  render local "$BATS_TEST_TMPDIR/out"
  for ns in cert-manager openbao; do
    policy="$BATS_TEST_TMPDIR/out/cilium-policy/${ns}_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
    [ "$(yq -r '.spec.ingress | length' "$policy")" -ge 1 ]
    [ "$(yq -r '.spec.egress | length' "$policy")" -ge 1 ]
    [ "$(yq -r '.spec.endpointSelector | length' "$policy")" -eq 0 ]
  done
  [ -e "$BATS_TEST_TMPDIR/out/cilium-policy/flux-system_cilium.io_v2_ciliumnetworkpolicy_platform.yaml" ]
}

@test "OpenBao is reachable on its pod port from the namespace of the package that requires secrets, and only there" {
  render local "$BATS_TEST_TMPDIR/out"
  provider="$BATS_TEST_TMPDIR/out/cilium-policy/openbao_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  consumer="$BATS_TEST_TMPDIR/out/cilium-policy/cert-manager_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress | length' "$provider")" -eq 1 ]
  [ "$(yq -r '.spec.ingress[0].fromEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"]' "$provider")" = cert-manager ]
  [ "$(yq -r '.spec.ingress[0].toPorts[0].ports[0].port' "$provider")" = 8443 ]
  [ "$(yq -r '.spec.egress[] | select(.toEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"] == "openbao") | .toPorts[0].ports[0].port' "$consumer")" = 8443 ]
}

@test "the node reaches exactly the host ports a package lists" {
  render local "$BATS_TEST_TMPDIR/out"
  consumer="$BATS_TEST_TMPDIR/out/cilium-policy/cert-manager_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities) | .fromEntities | join(",")' "$consumer")" = host ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities) | [.toPorts[0].ports[].port] | join(",")' "$consumer")" = 9403,6080,10250 ]
}

@test "the kubelet's probes of the flux-system pods are allowed from the node, and nothing else is changed there" {
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/flux-system_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress | length' "$policy")" -eq 1 ]
  [ "$(yq -r '.spec.ingress[0].fromEntities | join(",")' "$policy")" = host ]
  [ "$(yq -r '[.spec.ingress[0].toPorts[0].ports[].port] | join(",")' "$policy")" = 8081,9090,9440 ]
  [ "$(yq -r '.spec | has("egress")' "$policy")" = false ]
}

@test "kube-system denies ingress only: the node, every pod on DNS and its own pods are allowed, egress is untouched" {
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/kube-system_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec | has("egress")' "$policy")" = false ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities[0] == "host") | [.toPorts[0].ports[].port] | join(",")' "$policy")" = 8080,8181,8093,10250,4222,8081 ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities[0] == "cluster") | [.toPorts[0].ports[] | .port + "/" + .protocol] | join(",")' "$policy")" = 53/UDP,53/TCP ]
  [ "$(yq -r '[.spec.ingress[] | select(.fromEndpoints and (.fromEndpoints[0] | length) == 0)] | length' "$policy")" -eq 1 ]
  [ "$(yq -r '[.spec.ingress[] | select(.fromEntities and .fromEndpoints)] | length' "$policy")" -eq 0 ]
}

@test "the API server's webhook calls are allowed from the konnectivity agent, not from the node alone" {
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/cert-manager_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress[] | select(.fromEndpoints[0].matchLabels["k8s:k8s-app"] == "konnectivity-agent") | .toPorts[0].ports[].port' "$policy" | tr '\n' ,)" = 9403,6080,10250, ]
  # Cilium refuses an entity and an endpoint selector in one rule.
  [ "$(yq -r '[.spec.ingress[] | select(.fromEntities and .fromEndpoints)] | length' "$policy")" -eq 0 ]
}

@test "the policies of the platform namespaces stay byte-identical to the recorded render" {
  render local "$BATS_TEST_TMPDIR/out"
  for golden in "$root_directory"/tests/render/golden/platform-policy/*; do
    diff "$golden" "$BATS_TEST_TMPDIR/out/cilium-policy/$(basename "$golden")"
  done
}

@test "binding a tenant namespace that requires nothing leaves the policies of the platform namespaces byte-identical" {
  bind_site
  yq -i 'del(.requires)' packages/site/package.yaml
  render local "$BATS_TEST_TMPDIR/out"
  for golden in "$root_directory"/tests/render/golden/platform-policy/*; do
    diff "$golden" "$BATS_TEST_TMPDIR/out/cilium-policy/$(basename "$golden")"
  done
}

@test "one clusterwide policy denies both directions everywhere but the platform and system namespaces" {
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/cilium.io_v2_ciliumclusterwidenetworkpolicy_tenant-default-deny.yaml"
  [ "$(yq -r '.spec.endpointSelector.matchExpressions[0] | [.key, .operator] | join(" ")' "$policy")" = "io.kubernetes.pod.namespace NotIn" ]
  [ "$(yq -r '.spec.endpointSelector.matchExpressions[0].values | join(",")' "$policy")" = cert-manager,default,flux-system,kube-node-lease,kube-public,kube-system,openbao ]
  [ "$(yq -r '.spec.endpointSelector.matchExpressions[1] | [.key, .operator] | join(" ")' "$policy")" = "io.kubernetes.pod.namespace Exists" ]
  [ "$(yq -r '.spec.enableDefaultDeny | [.ingress, .egress] | join(",")' "$policy")" = true,true ]
  [ "$(yq -r '.spec.ingress | length' "$policy")" -eq 1 ]
  [ "$(yq -r '.spec.ingress[0] | length' "$policy")" -eq 0 ]
  [ "$(yq -r '.spec.egress | length' "$policy")" -eq 1 ]
  [ "$(yq -r '.spec.egress[0].toEndpoints[0].matchLabels["k8s:k8s-app"]' "$policy")" = kube-dns ]
}

@test "a tenant namespace is not excluded from the clusterwide policy" {
  bind_site
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/cilium.io_v2_ciliumclusterwidenetworkpolicy_tenant-default-deny.yaml"
  [ "$(yq -r '.spec.endpointSelector.matchExpressions[0].values | contains(["shop"])' "$policy")" = false ]
}

@test "a tenant namespace gets only its allows: the node on its host port, its provider on the pod port, no API server" {
  bind_site
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/shop_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress | length' "$policy")" -eq 2 ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities[0] == "host") | .toPorts[0].ports[0].port' "$policy")" = 44100 ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEndpoints[0].matchLabels["k8s:k8s-app"] == "konnectivity-agent") | .toPorts[0].ports[0].port' "$policy")" = 44100 ]
  [ "$(yq -r '.spec.egress | length' "$policy")" -eq 1 ]
  [ "$(yq -r '.spec.egress[0].toEndpoints[0].matchLabels["k8s:io.kubernetes.pod.namespace"]' "$policy")" = openbao ]
  [ "$(yq -r '[.spec.egress[] | select(.toEntities)] | length' "$policy")" -eq 0 ]
}

@test "a tenant package's ingress ports open exactly those pod ports to the Gateway's ingress entity" {
  bind_site
  printf 'ingress_ports:\n  - port: 44100\n    protocol: TCP\n' >>packages/site/package.yaml
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/shop_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '.spec.ingress | length' "$policy")" -eq 3 ]
  [ "$(yq -r '.spec.ingress[] | select(.fromEntities[0] == "ingress") | .toPorts[0].ports | map(.port + "/" + .protocol) | join(",")' "$policy")" = 44100/TCP ]
}

@test "a tenant package without ingress ports gets no rule for the ingress entity" {
  bind_site
  render local "$BATS_TEST_TMPDIR/out"
  policy="$BATS_TEST_TMPDIR/out/cilium-policy/shop_cilium.io_v2_ciliumnetworkpolicy_platform.yaml"
  [ "$(yq -r '[.spec.ingress[] | select(.fromEntities[0] == "ingress")] | length' "$policy")" -eq 0 ]
}

@test "a tenant namespace whose packages allow nothing gets no policy of its own" {
  bind_site
  yq -i 'del(.requires) | del(.host_ports)' packages/site/package.yaml
  render local "$BATS_TEST_TMPDIR/out"
  [ ! -e "$BATS_TEST_TMPDIR/out/cilium-policy/shop_cilium.io_v2_ciliumnetworkpolicy_platform.yaml" ]
  grep -q 'tenant-default-deny' "$BATS_TEST_TMPDIR/out/cilium-policy/cilium.io_v2_ciliumclusterwidenetworkpolicy_tenant-default-deny.yaml"
}

@test "the release of Cilium reads the network policy's values as an optional second source" {
  render local "$BATS_TEST_TMPDIR/out"
  config="$BATS_TEST_TMPDIR/out/cilium-policy/flux-system_v1_configmap_cilium-values-policy.yaml"
  [ "$(yq -r '.data["values.yaml"] | from_yaml | .extraConfig["allow-localhost"]' "$config")" = policy ]
  [ "$(yq -r '.metadata.labels["reconcile.fluxcd.io/watch"]' "$config")" = Enabled ]
  [ "$(yq -r '.spec.valuesFrom[1] | [.name, .optional] | join(",")' "$root_directory/packages/cilium/helmrelease.yaml")" = cilium-values-policy,true ]
}

@test "a tenant namespace gets an installer account in flux-system and the admin role in its own namespace only" {
  render local "$BATS_TEST_TMPDIR/out"
  account="$BATS_TEST_TMPDIR/out/namespace/flux-system_v1_serviceaccount_installer-cv.yaml"
  binding="$BATS_TEST_TMPDIR/out/namespace/cv_rbac.authorization.k8s.io_v1_rolebinding_installer-cv.yaml"
  [ "$(yq -r '.metadata.namespace' "$account")" = flux-system ]
  [ "$(yq -r '[.roleRef.kind, .roleRef.name] | join(",")' "$binding")" = ClusterRole,admin ]
  [ "$(yq -r '.subjects[0] | [.kind, .name, .namespace] | join(",")' "$binding")" = ServiceAccount,installer-cv,flux-system ]
  [ "$(find "$BATS_TEST_TMPDIR/out/namespace" -name '*installer*' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a tenant chart installs as its installer account and a platform chart keeps the controller's authority" {
  render local "$BATS_TEST_TMPDIR/out"
  [ "$(yq -r '.spec.serviceAccountName' "$BATS_TEST_TMPDIR/out/cv/helm.toolkit.fluxcd.io_v2_helmrelease_cv.yaml")" = installer-cv ]
  for package in cert-manager openbao; do
    [ "$(yq -r '.spec | has("serviceAccountName")' "$BATS_TEST_TMPDIR/out/$package/helm.toolkit.fluxcd.io_v2_helmrelease_$package.yaml")" = false ]
  done
}

@test "a tenant namespace enforces the baseline Pod Security Standard and a platform namespace carries no such label" {
  render local "$BATS_TEST_TMPDIR/out"
  [ "$(yq -r '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$BATS_TEST_TMPDIR/out/namespace/v1_namespace_cv.yaml")" = baseline ]
  for ns in cert-manager openbao flux-system kube-system; do
    [ "$(yq -r '.metadata.labels | has("pod-security.kubernetes.io/enforce")' "$BATS_TEST_TMPDIR/out/namespace/v1_namespace_$ns.yaml")" = false ]
  done
}

@test "a retired binding installs no chart and keeps its namespace, quota, installer and policy" {
  render local "$BATS_TEST_TMPDIR/before"
  yq -i '(.[] | select(.package == "cv")).retired = true' clusters/singularity/packages.yaml
  render local "$BATS_TEST_TMPDIR/after"
  [ ! -e "$BATS_TEST_TMPDIR/after/cv" ]
  diff -r "$BATS_TEST_TMPDIR/before/namespace" "$BATS_TEST_TMPDIR/after/namespace"
  diff -r "$BATS_TEST_TMPDIR/before/cilium-policy" "$BATS_TEST_TMPDIR/after/cilium-policy"
  [ "$(cue export .:inputs -e 'retired.local' --out json | jq -c .)" = '[{"package":"cv","namespace":"cv"}]' ]
}

@test "a bootstrap package marked retired is refused, naming it" {
  yq -i '(.[] | select(.package == "cilium")).retired = true' clusters/singularity/packages.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *cilium* ]]
}

@test "a binding that sets retired to false is refused, naming the field" {
  yq -i '(.[] | select(.package == "cv")).retired = false' clusters/singularity/packages.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *retired* ]]
}

@test "a tenant without a kind is refused, naming the field" {
  sed -i.bak '/^kind:/d' environments/local/tenants/platform.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *kind* ]]
}

@test "a tenant quota of the wrong type is refused, naming the field" {
  sed -i.bak 's/^  cpu: .*/  cpu: [1]/' environments/local/tenants/platform.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *cpu* ]]
}

@test "a tenant still using the old quota field is refused, naming it" {
  sed -i.bak 's/^namespace_quota:/quota:/' environments/local/tenants/apps.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *quota* ]]
}

@test "an environment the data does not define fails the render, naming it" {
  run render nope "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *nope* ]]
}

@test "a missing ENVIRONMENT variable fails the render" {
  run env -u ENVIRONMENT timoni bundle build -f render/bundle.cue --runtime-from-env --output-dir "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *environment* ]]
}

@test "each namespace carries its tenant label and the tenant's quota" {
  render local "$BATS_TEST_TMPDIR/out"
  grep -q 'firmament.dev/tenant: platform' "$BATS_TEST_TMPDIR/out/namespace/v1_namespace_flux-system.yaml"
  grep -q 'requests.cpu: "16"' "$BATS_TEST_TMPDIR/out/namespace/flux-system_v1_resourcequota_tenant.yaml"
}

@test "each namespace defaults container requests so its quota admits pods that set none" {
  render local "$BATS_TEST_TMPDIR/out"
  grep -q 'defaultRequest:' "$BATS_TEST_TMPDIR/out/namespace/kube-system_v1_limitrange_tenant-defaults.yaml"
  grep -q 'defaultRequest:' "$BATS_TEST_TMPDIR/out/namespace/flux-system_v1_limitrange_tenant-defaults.yaml"
}

@test "the cv site installs into its own namespace of the apps tenant, from a chart whose signer Flux checks" {
  render local "$BATS_TEST_TMPDIR/out"
  chart="$BATS_TEST_TMPDIR/out/cv"
  [ "$(yq -r '.spec.ref.digest' "$chart/source.toolkit.fluxcd.io_v1_ocirepository_cv.yaml")" = "$(yq -r '.pin.digest' packages/cv/package.yaml)" ]
  [ "$(yq -r '.spec.verify.provider' "$chart/source.toolkit.fluxcd.io_v1_ocirepository_cv.yaml")" = cosign ]
  [ "$(yq -r '.spec.targetNamespace' "$chart/helm.toolkit.fluxcd.io_v2_helmrelease_cv.yaml")" = cv ]
  [ "$(yq -r '.data["values.yaml"] | from_yaml | .image.digest' "$chart/v1_configmap_cv-values.yaml")" = "$(yq -r '.image.digest' clusters/singularity/values/cv.yaml)" ]
  grep -q 'firmament.dev/tenant: apps' "$BATS_TEST_TMPDIR/out/namespace/v1_namespace_cv.yaml"
}

@test "each chart package renders its source pinned by digest, its values and its release" {
  render local "$BATS_TEST_TMPDIR/out"
  chart="$BATS_TEST_TMPDIR/out/cert-manager"
  [ "$(yq -r '.spec.ref.digest' "$chart/source.toolkit.fluxcd.io_v1_ocirepository_cert-manager.yaml")" = "$(yq -r '.pin.digest' packages/cert-manager/package.yaml)" ]
  [ "$(yq -r '.metadata.labels["reconcile.fluxcd.io/watch"]' "$chart/v1_configmap_cert-manager-values.yaml")" = Enabled ]
  [ "$(yq -r '.data["values.yaml"] | from_yaml | .crds.enabled' "$chart/v1_configmap_cert-manager-values.yaml")" = true ]
  release="$chart/helm.toolkit.fluxcd.io_v2_helmrelease_cert-manager.yaml"
  [ "$(yq -r '.spec.targetNamespace' "$release")" = cert-manager ]
  [ "$(yq -r '.spec.valuesFrom[0].name' "$release")" = cert-manager-values ]
  [ "$(yq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' "$release")" = disabled ]
}

@test "a chart package with a verify block renders the source with keyless cosign verification" {
  yq -i '.verify.issuer = "^https://issuer\\.example$" | .verify.identity = "^https://example/signer$"' packages/cert-manager/package.yaml
  render local "$BATS_TEST_TMPDIR/out"
  source="$BATS_TEST_TMPDIR/out/cert-manager/source.toolkit.fluxcd.io_v1_ocirepository_cert-manager.yaml"
  [ "$(yq -r '.spec.verify.provider' "$source")" = cosign ]
  [ "$(yq -r '.spec.verify.matchOIDCIdentity | length' "$source")" -eq 1 ]
  [ "$(yq -r '.spec.verify.matchOIDCIdentity[0].issuer' "$source")" = '^https://issuer\.example$' ]
  [ "$(yq -r '.spec.verify.matchOIDCIdentity[0].subject' "$source")" = '^https://example/signer$' ]
}

@test "a chart package without a verify block renders no verification" {
  render local "$BATS_TEST_TMPDIR/out"
  [ "$(yq -r '.spec | has("verify")' "$BATS_TEST_TMPDIR/out/cert-manager/source.toolkit.fluxcd.io_v1_ocirepository_cert-manager.yaml")" = false ]
}

@test "an empty verify block is refused, naming the missing field" {
  yq -i '.verify = {}' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *issuer* ]]
}

@test "a verify block with an unknown key is refused, naming it" {
  yq -i '.verify.issuer = "^a$" | .verify.identity = "^b$" | .verify.keyless = true' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *keyless* ]]
}

@test "a verify identity that is not anchored is refused, naming the field" {
  yq -i '.verify.issuer = "^a$" | .verify.identity = "signer"' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *identity* ]]
}

@test "the bootstrap packages stay plain: the render holds no instance for them" {
  render local "$BATS_TEST_TMPDIR/out"
  [ ! -e "$BATS_TEST_TMPDIR/out/cilium" ]
  [ ! -e "$BATS_TEST_TMPDIR/out/flux" ]
}

@test "two renders of one environment are byte-identical" {
  render local "$BATS_TEST_TMPDIR/first"
  render local "$BATS_TEST_TMPDIR/second"
  diff -r "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/second"
}

@test "the vendored tenant schema equals its contract" {
  diff "$work/contracts/tenant-spec/schema.cue" "$work/packages/namespace/module/cue.mod/pkg/firmament.dev/tenant-spec/schema.cue"
}

@test "a package.yaml whose layer is outside the closed set is refused, naming the field" {
  sed -i.bak 's/^layer: trust$/layer: trsut/' packages/cert-manager/package.yaml
  run cue vet -c .:inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *layer* ]]
}

@test "the vendored package schema equals its contract" {
  diff "$work/contracts/package-spec/schema.cue" "$work/packages/chart/module/cue.mod/pkg/firmament.dev/package-spec/schema.cue"
}

@test "every declared environment renders into its own directory of its cluster" {
  declare_stage_environment
  render_all
  grep -q 'requests.cpu: "16"' clusters/singularity/rendered/local/namespace/flux-system_v1_resourcequota_tenant.yaml
  grep -q 'requests.cpu: "8"' clusters/singularity/rendered/stage/namespace/flux-system_v1_resourcequota_tenant.yaml
}

@test "the render of one environment is byte-identical to a direct build of it" {
  render_all
  render local "$BATS_TEST_TMPDIR/direct"
  diff -r "$BATS_TEST_TMPDIR/direct" clusters/singularity/rendered/local
}

@test "two renders of every environment are byte-identical" {
  declare_stage_environment
  render_all
  cp -R clusters/singularity/rendered "$BATS_TEST_TMPDIR/first"
  render_all
  diff -r "$BATS_TEST_TMPDIR/first" clusters/singularity/rendered
}

@test "a build that fails leaves the last complete render in place" {
  render_all
  cp -R clusters/singularity/rendered "$BATS_TEST_TMPDIR/before"
  declare_stage_environment
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n[ "$ENVIRONMENT" != stage ] || exit 1\nexec %s "$@"\n' "$(command -v timoni)" >"$BATS_TEST_TMPDIR/bin/timoni"
  chmod +x "$BATS_TEST_TMPDIR/bin/timoni"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" MISE_PROJECT_ROOT="$work" "$work/.mise/tasks/render.sh"
  [ "$status" -ne 0 ]
  diff -r "$BATS_TEST_TMPDIR/before" clusters/singularity/rendered
}

@test "data the schema refuses leaves the last complete render in place" {
  render_all
  cp -R clusters/singularity/rendered "$BATS_TEST_TMPDIR/before"
  sed -i.bak '/^kind:/d' environments/local/tenants/platform.yaml
  run render_all
  [ "$status" -ne 0 ]
  diff -r "$BATS_TEST_TMPDIR/before" clusters/singularity/rendered
}

@test "an environment that is no longer declared leaves no rendered directory" {
  declare_stage_environment
  render_all
  [ -d clusters/singularity/rendered/stage ]
  rm -rf environments/stage
  render_all
  [ ! -e clusters/singularity/rendered/stage ]
  [ -d clusters/singularity/rendered/local ]
}
