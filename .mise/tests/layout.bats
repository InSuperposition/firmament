#!/usr/bin/env bats

# layout:lint and layout:format on a small stand-in repository: three
# folders, and one package of each kind. The repository's own .mise is
# linked in untracked, so git never lists it.

# shellcheck disable=SC2016 # backticks in single quotes are literal Markdown
bats_require_minimum_version 1.5.0

load stubs.bash

setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  mkdir -p "$repository/contracts/layout" "$repository/packages/a-flux" "$repository/timoni/modules/b-render" "$repository/timoni/bundles" "$repository/packages/c-manifests"
  ln -sfn "$root_directory/.mise" "$repository/.mise"
  cat >"$repository/contracts/layout/layout.yaml" <<'YAML'
folders:
  contracts:
    holds: the contracts
    may_reference: []
    must_never: [reference another folder]
  packages:
    holds: the packages
    may_reference: [contracts]
    must_never: [name a cluster]
  timoni:
    holds: the modules and bundles
    may_reference: []
    must_never: [embed data files]
    subfolders:
      bundles:
        holds: the bundles
        may_reference: [timoni/modules]
        must_never: [embed data files]
      modules:
        holds: the modules
        may_reference: []
        must_never: [reference a package]
top_level_files:
  holds: README.md
package_kinds:
  flux-package:
    holds: a directory with package.yaml
  manifest-only:
    holds: a directory with neither and a top-level manifest
find:
  - question: Find the packages
    path: packages
cluster_name_places: [clusters/<name>/]
standalone_checks: []
review_checks: [a package names no cluster]
YAML
  : >"$repository/packages/a-flux/package.yaml"
  : >"$repository/timoni/modules/b-render/timoni.cue"
  : >"$repository/timoni/bundles/bundle.cue"
  : >"$repository/packages/c-manifests/crds.yaml"
  for package in a-flux c-manifests; do printf '# %s\n' "$package" >"$repository/packages/$package/README.md"; done
  printf '# b-render\n' >"$repository/timoni/modules/b-render/README.md"
  printf '# stand-in\n\n<!-- layout:begin -->\n<!-- layout:end -->\n' >"$repository/README.md"
  git -C "$repository" init -q
  git -C "$repository" add README.md contracts packages timoni
  export MISE_PROJECT_ROOT="$repository"
  format
}

lint() { run "$root_directory/.mise/tasks/layout/lint.sh"; }
format() { run "$root_directory/.mise/tasks/layout/format.sh"; }
readme_hash() { shasum "$repository/README.md" | cut -d' ' -f1; }

@test "layout:lint accepts the repository" {
  MISE_PROJECT_ROOT="$root_directory" run "$root_directory/.mise/tasks/layout/lint.sh"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "layout:lint accepts the stand-in once layout:format has written its block" {
  lint
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "layout:lint names a tracked folder that layout.yaml leaves out" {
  mkdir "$repository/extra" && : >"$repository/extra/file" && git -C "$repository" add extra
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"the tracked folder extra/ is not in contracts/layout/layout.yaml"* ]]
}

@test "layout:lint names a folder that layout.yaml lists but the tree does not track" {
  yq -i 'del(.folders.packages)' "$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"the tracked folder packages/ is not in contracts/layout/layout.yaml"* ]]
  yq -i '.folders.ghost = {"holds": "nothing", "may_reference": [], "must_never": []}' "$repository/contracts/layout/layout.yaml"
  lint
  [[ "$output" == *"lists ghost, which is not a tracked folder"* ]]
}

@test "layout:lint names a may_reference entry that is not a folder" {
  yq -i '.folders.packages.may_reference = ["nowhere"]' "$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"folders.packages.may_reference names nowhere, which is not a folder or a subfolder"* ]]
}

@test "layout:lint names a find path that is not in the tracked tree" {
  yq -i '.find[0].path = "packages/gone"' "$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"the find path packages/gone is not in the tracked tree"* ]]
}

@test "layout:lint and layout:format refuse absent or duplicated markers and format leaves the README alone" {
  printf '# stand-in\n' >"$repository/README.md"
  before=$(readme_hash)
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 begin marker(s) and 0 end marker(s)"* ]]
  format
  [ "$status" -ne 0 ]
  [[ "$output" == *"layout:format wrote nothing"* ]]
  [ "$(readme_hash)" = "$before" ]
  printf '<!-- layout:begin -->\n<!-- layout:begin -->\n<!-- layout:end -->\n' >"$repository/README.md"
  before=$(readme_hash)
  format
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 begin marker(s) and 1 end marker(s)"* ]]
  [ "$(readme_hash)" = "$before" ]
}

@test "layout:lint refuses an end marker before the begin marker" {
  printf '<!-- layout:end -->\n<!-- layout:begin -->\n' >"$repository/README.md"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"end marker before its begin marker"* ]]
}

@test "layout:lint shows a difference when the generated block was edited by hand" {
  sed -i.bak 's/the packages/THE PACKAGES/' "$repository/README.md" && rm "$repository/README.md.bak"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the render of contracts/layout/layout.yaml; run mise run layout:format"* ]]
  [[ "$output" == *"THE PACKAGES"* ]]
}

@test "layout:format writes only between the markers and a second run changes nothing" {
  printf 'before\n\n<!-- layout:begin -->\nstale\n<!-- layout:end -->\n\nafter\n' >"$repository/README.md"
  format
  [ "$status" -eq 0 ]
  head -1 "$repository/README.md" | grep -qx 'before'
  tail -1 "$repository/README.md" | grep -qx 'after'
  run ! grep -q '^stale$' "$repository/README.md"
  grep -q '| `a-flux` | `flux-package` |' "$repository/README.md"
  grep -q '| `b-render` | \[timoni/modules/b-render/README.md\]' "$repository/README.md"
  grep -q '| `timoni/modules/` | the modules |' "$repository/README.md"
  grep -q '| `c-manifests` | `manifest-only` |' "$repository/README.md"
  after=$(readme_hash)
  format
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readme_hash)" = "$after" ]
}

@test "layout:lint never writes the README" {
  sed -i.bak 's/the packages/THE PACKAGES/' "$repository/README.md" && rm "$repository/README.md.bak"
  before=$(readme_hash)
  lint
  [ "$status" -ne 0 ]
  [ "$(readme_hash)" = "$before" ]
}

@test "layout:lint refuses a package that fits no kind, and a Timoni module returned to packages/" {
  mkdir "$repository/packages/d-empty" && printf '# d\n' >"$repository/packages/d-empty/README.md"
  git -C "$repository" add packages/d-empty
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/d-empty fits no kind"* ]]
  mkdir -p "$repository/packages/e-module/module" && : >"$repository/packages/e-module/module/timoni.cue" && printf '# e\n' >"$repository/packages/e-module/README.md"
  git -C "$repository" add packages/e-module
  lint
  [[ "$output" == *"packages/e-module fits no kind"* ]]
  [[ "$output" == *"a Timoni module belongs in timoni/modules/"* ]]
}

@test "layout:lint names a Timoni module without a tracked README" {
  git -C "$repository" rm -q --cached timoni/modules/b-render/README.md
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"timoni/modules/b-render has no tracked README.md"* ]]
}

@test "layout:format lists a Timoni module in its table, and marks one without a README as missing" {
  git -C "$repository" rm -q --cached timoni/modules/b-render/README.md
  format
  grep -q '| `b-render` | missing |' "$repository/README.md"
}

@test "layout:lint names a subfolder the tree tracks and layout.yaml leaves out, and the reverse" {
  mkdir "$repository/timoni/extra" && : >"$repository/timoni/extra/file" && git -C "$repository" add timoni/extra
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"the tracked folder timoni/extra/ is not in folders.timoni.subfolders"* ]]
  git -C "$repository" rm -q -f --cached timoni/extra/file
  yq -i '.folders.timoni.subfolders.ghost = {"holds": "nothing", "may_reference": [], "must_never": []}' "$repository/contracts/layout/layout.yaml"
  lint
  [[ "$output" == *"folders.timoni.subfolders lists ghost, which is not a tracked folder"* ]]
}

@test "layout:lint accepts a subfolder reference and names one that does not exist" {
  yq -i '.folders.timoni.subfolders.bundles.may_reference = ["timoni/nowhere"]' "$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"folders.timoni.subfolders.bundles.may_reference names timoni/nowhere, which is not a folder or a subfolder"* ]]
}

@test "layout:lint names a package without a README, and one whose README is not tracked" {
  git -C "$repository" rm -q --cached packages/a-flux/README.md
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"packages/a-flux has no tracked README.md"* ]]
  [ -f "$repository/packages/a-flux/README.md" ]
}

@test "layout:lint ignores a file directly under packages/" {
  printf 'notes\n' >"$repository/packages/notes.txt" && git -C "$repository" add packages/notes.txt
  lint
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "layout:lint says so when layout.yaml is not readable YAML" {
  printf 'folders: [unclosed\n' >"$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not readable YAML with a folders map"* ]]
}

@test "the pre-commit and pre-push hooks run layout:lint" {
  run awk '/\["layout"\] \{/,/\}/' "$root_directory/hk.pkl"
  [[ "$output" == *'check = "mise run layout:lint"'* ]]
}
