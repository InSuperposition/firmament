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

@test "two renders of one environment are byte-identical" {
  render local "$BATS_TEST_TMPDIR/first"
  render local "$BATS_TEST_TMPDIR/second"
  diff -r "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/second"
}

@test "the vendored tenant schema equals its contract" {
  diff "$work/contracts/tenant-spec/schema.cue" "$work/packages/namespace/module/cue.mod/pkg/firmament.dev/tenant-spec/schema.cue"
}
