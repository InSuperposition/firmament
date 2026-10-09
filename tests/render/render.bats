#!/usr/bin/env bats

# Each test renders a private copy of the data files and the render code, so
# a planted fault never touches the working tree.

setup() {
  root_directory="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  work="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$work"
  cp -R "$root_directory"/{cue.mod,inputs.cue,bundle.cue,contracts,packages,clusters,environments} "$work"
  rm -rf "$work/clusters/singularity/rendered"
  cd "$work"
}

render() {
  ENVIRONMENT="${1:-local}" timoni bundle build -f bundle.cue --runtime-from-env --output-dir "$2"
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

@test "an environment the data does not define fails the render, naming it" {
  run render nope "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *nope* ]]
}

@test "a missing ENVIRONMENT variable fails the render" {
  run env -u ENVIRONMENT timoni bundle build -f bundle.cue --runtime-from-env --output-dir "$BATS_TEST_TMPDIR/out"
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

@test "the vendored package schema equals its contract" {
  diff "$work/contracts/package-spec/schema.cue" "$work/packages/chart/module/cue.mod/pkg/firmament.dev/package-spec/schema.cue"
}
