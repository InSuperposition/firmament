#!/usr/bin/env bash
#MISE description="Rebuild the environment's cluster once per kube-proxy mode and run every live check against each; destroys the cluster and leaves it destroyed (about 30 to 40 minutes)"
#MISE confirm="Destroy environment {{usage.environment}}, rebuild it twice for the end-to-end run, and leave it destroyed?"
#USAGE arg "[environment]" default="local" help="Directory name under environment/"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"
# shellcheck disable=SC2154 # mise sets usage_* from the #USAGE spec
environment="$usage_environment"

#   destroy
#   pass true:  apply > recorded mode > verify > conformance
#               > switching to false must be refused > destroy
#   pass false: apply > recorded mode > verify > conformance > destroy
#
# The first failing step stops the run and leaves the cluster as it is, so
# the failure can be inspected. The next run starts with a destroy.

# Runs one step, or stops the run and says how to clean up.
step() {
  if ! "$@"; then
    fail "env:e2e stopped at: $*"$'\n'"The cluster is left as it is. Remove it with: mise run --yes env:destroy $environment"
    exit 1
  fi
}

# Fails unless state records the kube-proxy mode the pass applied.
expect_recorded_mode() {
  local expected="$1" recorded
  init_environment "$environment" || return
  recorded=$(environment_output "$environment" kube_proxy_replacement) || return
  if [[ "$recorded" != "$expected" ]]; then
    fail "state records kube_proxy_replacement=$recorded, expected $expected"
  fi
}

# Fails unless planning the other kube-proxy mode is refused on the live
# cluster, because the mode is fixed at creation.
expect_mode_switch_refused() {
  local mode="$1" output
  if output=$(TF_VAR_kube_proxy_replacement="$mode" mise run env:plan "$environment" 2>&1); then
    fail "env:plan accepted kube_proxy_replacement=$mode on a live cluster"
    return
  fi
  if [[ "$output" != *"fixed at cluster creation"* ]]; then
    printf '%s\n' "$output" >&2
    fail "env:plan failed, but not because the kube-proxy mode is fixed at creation"
  fi
}

# Applies the environment in one kube-proxy mode and runs every live check.
# The mode is set explicitly, so an inherited value cannot change the pass.
run_pass() {
  export TF_VAR_kube_proxy_replacement="$1"
  step mise run env:apply "$environment"
  step expect_recorded_mode "$1"
  step mise run verify "$environment"
  step mise run cilium:conformance "$environment"
}

environment_directory "$environment" >/dev/null

step mise run --yes env:destroy "$environment"
run_pass true
step expect_mode_switch_refused false
step mise run --yes env:destroy "$environment"
run_pass false
step mise run --yes env:destroy "$environment"
printf 'env:e2e passed for %s in both kube-proxy modes; the cluster is destroyed.\n' "$environment"
