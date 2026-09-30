# shellcheck shell=bash
# Flux helpers: the revision Flux reports and the offline render of an
# environment's Flux build.

# Prints the revision Flux reports once it has applied a branch at the tip
# origin had when last fetched.
flux_revision() {
  local sha
  sha=$(remote_branch_sha "$1") || return
  printf 'refs/heads/%s@sha1:%s\n' "$1" "$sha"
}

# Prints the stand-in runtime values in .mise/flux-test-values.env as
# KEY=value lines, without comments or blank lines.
flux_test_values() {
  grep -Ev '^[[:space:]]*(#|$)' "${MISE_PROJECT_ROOT:?run this through mise}/.mise/flux-test-values.env"
}

# Renders what Flux applies from an environment's flux directory, with the
# stand-in values in place of the runtime values OpenTofu computes. Fails on
# a variable left without a value.
render_flux_build() {
  local -a values
  mapfile -t values < <(flux_test_values)
  kubectl kustomize "$1" | env "${values[@]}" flux envsubst --strict
}
