#!/usr/bin/env bats

# Each test works on a private copy of the data files and the inventory code,
# so a planted fault never touches the working tree.

setup() {
  root_directory="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  work="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$work/.mise"
  cp -R "$root_directory"/{cue.mod,inputs.cue,render,contracts,packages,clusters,environments} "$work"
  cp "$root_directory/.mise/lib.sh" "$work/.mise/"
  cd "$work"
}

@test "the local inventory equals its golden file" {
  cue export render/inventory.cue -e inventory.local --out json >"$BATS_TEST_TMPDIR/local.json"
  diff "$root_directory/tests/render/golden/inventory/local.json" "$BATS_TEST_TMPDIR/local.json"
}

@test "inventory:generate writes the golden inventory into the state directory" {
  state="$BATS_TEST_TMPDIR/state/local"
  MISE_PROJECT_ROOT="$work" TF_VAR_state_directory="$state" MISE_ENV=local \
    bash "$root_directory/.mise/tasks/inventory/generate.sh"
  diff "$root_directory/tests/render/golden/inventory/local.json" "$state/inventory.json"
}

@test "inventory:lint passes on the data files" {
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -eq 0 ]
}

@test "a binding to a tenant the environment does not define is refused, naming it" {
  printf -- '- package: cilium\n  namespace: shop\n  tenant: ghost\n' >>clusters/singularity/packages.yaml
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *ghost* ]]
}

@test "a binding to a package that does not exist is refused, naming it" {
  printf -- '- package: ghost\n  namespace: shop\n  tenant: platform\n' >>clusters/singularity/packages.yaml
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *ghost* ]]
}

@test "a namespace bound to two tenants is refused" {
  printf -- '- package: cv\n  namespace: openbao\n  tenant: apps\n' >>clusters/singularity/packages.yaml
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -ne 0 ]
}

@test "a chart pin without a digest is refused, naming the field" {
  yq -i 'del(.pin.digest)' packages/cv/package.yaml
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *digest* ]]
}

@test "a schema that lacks a field the inventory carries refuses it, naming the field" {
  grep -v 'signed' contracts/inventory/schema.cue >"$BATS_TEST_TMPDIR/schema.cue"
  mv "$BATS_TEST_TMPDIR/schema.cue" contracts/inventory/schema.cue
  MISE_PROJECT_ROOT="$work" run bash "$root_directory/.mise/tasks/inventory/lint.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *signed* ]]
}
