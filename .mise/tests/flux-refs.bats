#!/usr/bin/env bats

# flux-refs:lint on a small stand-in repository: one cluster whose flux
# folder holds three Kustomizations, a tracked folder with a HelmRelease, and
# a generated folder. The repository's own .mise is linked in untracked, so
# git never lists it.

bats_require_minimum_version 1.5.0

load stubs.bash

setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  flux="$repository/clusters/alpha/flux"
  mkdir -p "$flux" "$repository/clusters/alpha/payload" "$repository/clusters/alpha/workloads/dev/app" "$repository/.github/workflows"
  ln -sfn "$root_directory/.mise" "$repository/.mise"
  printf 'clusters/*/workloads/\nclusters/*/admission/\n' >"$repository/.gitignore"
  cat >"$repository/.github/workflows/publish.yaml" <<'YAML'
steps:
  - run: flux push artifact "oci://$ARTIFACT" --path . --ignore-paths '/*,!/clusters/,!/packages/' --reproducible
YAML
  cat >"$flux/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - payload.yaml
  - rendered.yaml
YAML
  kustomization payload payload ./clusters/alpha/payload "" "flux-system/cilium" >"$flux/payload.yaml"
  kustomization rendered rendered './clusters/alpha/workloads/${environment}' "payload" "flux-system/app" >"$flux/rendered.yaml"
  cat >"$repository/clusters/alpha/payload/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium.yaml
YAML
  helm_release cilium >"$repository/clusters/alpha/payload/cilium.yaml"
  helm_release app >"$repository/clusters/alpha/workloads/dev/app/release.yaml"
  git -C "$repository" init -q
  git -C "$repository" add .
  export MISE_PROJECT_ROOT="$repository"
}

# kustomization <name> <label> <path> <depends-on name or ""> <namespace/name of a HelmRelease to wait for>
kustomization() {
  cat <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $1
  namespace: flux-system
spec:
  path: '$3'
YAML
  [[ -z "$4" ]] || printf '  dependsOn:\n    - name: %s\n' "$4"
  printf '  healthChecks:\n    - apiVersion: helm.toolkit.fluxcd.io/v2\n      kind: HelmRelease\n      namespace: %s\n      name: %s\n' "${5%/*}" "${5#*/}"
}

helm_release() {
  printf 'apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: %s\n  namespace: flux-system\n' "$1"
}

lint() { run --separate-stderr "$root_directory/.mise/tasks/flux-refs/lint.sh"; }

@test "flux-refs:lint accepts the repository" {
  MISE_PROJECT_ROOT="$root_directory" run "$root_directory/.mise/tasks/flux-refs/lint.sh"
  [ "$status" -eq 0 ]
}

@test "flux-refs:lint accepts the stand-in repository" {
  lint
  [ "$status" -eq 0 ]
}

@test "flux-refs:lint rejects a dependsOn name no Kustomization defines" {
  sed -i.bak 's/- name: payload/- name: paylaod/' "$flux/rendered.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"depends on paylaod"* ]]
}

@test "flux-refs:lint rejects a tracked path with no tracked file" {
  sed -i.bak 's#./clusters/alpha/payload#./clusters/alpha/payloda#' "$flux/payload.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"holds no tracked file"* ]]
}

@test "flux-refs:lint rejects a generated path the trees file does not name" {
  sed -i.bak 's#/workloads/#/workloadz/#' "$flux/rendered.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not generate for alpha"* ]]
}

@test "flux-refs:lint rejects a path variable it cannot resolve" {
  sed -i.bak 's/${environment}/${cluster}/' "$flux/rendered.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"variable the check cannot resolve"* ]]
}

@test "flux-refs:lint rejects a generated folder that .gitignore does not ignore" {
  : >"$repository/.gitignore"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *".gitignore does not ignore it"* ]]
}

@test "flux-refs:lint rejects a generated folder that holds a tracked file" {
  git -C "$repository" add -f clusters/alpha/workloads
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"generated but holds tracked files"* ]]
}

@test "flux-refs:lint rejects a path the artifact does not publish" {
  sed -i.bak 's#,!/clusters/##' "$repository/.github/workflows/publish.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not publish"* ]]
}

@test "flux-refs:lint rejects a workflow with no flux push artifact line" {
  : >"$repository/.github/workflows/publish.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no flux push artifact line"* ]]
}

@test "flux-refs:lint rejects a healthCheck for a HelmRelease the path does not build" {
  sed -i.bak 's#name: cilium#name: cilum#' "$flux/payload.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"waits for HelmRelease flux-system/cilum"* ]]
}

@test "flux-refs:lint rejects a healthCheck for a HelmRelease in another namespace" {
  sed -i.bak 's#namespace: flux-system#namespace: other#' "$flux/payload.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"waits for HelmRelease other/cilium"* ]]
}

@test "flux-refs:lint reports an unrendered generated folder instead of failing" {
  rm -rf "$repository/clusters/alpha/workloads"
  lint
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is not rendered"* ]]
}

@test "flux-refs:lint rejects a manifest that kustomization.yaml does not list" {
  kustomization extra extra ./clusters/alpha/payload "" "flux-system/cilium" >"$flux/extra.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"extra.yaml is not listed"* ]]
}
