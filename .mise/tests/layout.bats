#!/usr/bin/env bats

load stubs.bash

# Each test runs layout:lint on a small repository that follows the layout
# contract, after planting one violation in it. The repository has one
# environment (sample), one cluster (edge) whose role is workload, one
# package, one module, and a legacy environment file the contract excepts.
setup() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  repository="$BATS_TEST_TMPDIR/repository"
  export MISE_PROJECT_ROOT="$repository"
  mkdir -p "$repository/contracts/layout"
  cp "$root_directory/contracts/layout/layout.cue" "$repository/contracts/layout/"
  yq '.exceptions = [{
      "rule": "environments-no-code",
      "paths": ["environments/sample/legacy.tf"],
      "owners": ["machines-orbstack"],
      "reason": "a legacy root the test keeps"
    }]' "$root_directory/contracts/layout/layout.yaml" >"$repository/contracts/layout/layout.yaml"
  plant environments/sample/environment.yaml 'clusters: [edge]'
  plant environments/sample/tests/cluster/chainsaw-test.yaml 'kind: Test'
  plant environments/sample/legacy.tf 'locals {}'
  plant clusters/edge/cluster.yaml 'role: workload'
  plant clusters/edge/values/net-sample.yaml 'mtu: 1450'
  plant packages/net-sample/values.yaml 'listen: 0.0.0.0'
  plant packages/net-sample/tests/values.bats '@test "x" { true; }'
  plant modules/vm-sample/main.tf 'variable "name" {}'
  mkdir -p "$repository/.mise/tasks/net-sample" "$repository/.mise/tasks/orb"
  git -C "$repository" init -q
}

# Writes a file into the repository with the given content.
plant() {
  mkdir -p "$repository/$(dirname -- "$1")"
  printf '%s\n' "$2" >"$repository/$1"
}

lint() {
  run "$root_directory/.mise/tasks/layout/lint.sh"
}

# Checks that the lint failed and named the file and the rule.
assert_violation() {
  [ "$status" -eq 1 ]
  [[ "$output" == *"layout:lint: $1: $2:"* ]] || {
    printf 'expected %s: %s in:\n%s\n' "$1" "$2" "$output" >&2
    return 1
  }
}

@test "accepts a repository that follows the layout" {
  lint
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "accepts the repository itself" {
  MISE_PROJECT_ROOT="$root_directory" run "$root_directory/.mise/tasks/layout/lint.sh"
  [ "$status" -eq 0 ]
}

@test "rejects a contract that does not match its schema" {
  yq -i '.folders.packages.may_reference = ["nowhere"]' "$repository/contracts/layout/layout.yaml"
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match its schema"* ]]
}

@test "rejects code in an environment" {
  plant environments/sample/apply.sh 'true'
  lint
  assert_violation environments/sample/apply.sh environments-no-code
}

@test "rejects an executable file in an environment whatever its name" {
  plant environments/sample/run 'true'
  chmod +x "$repository/environments/sample/run"
  lint
  assert_violation environments/sample/run environments-no-code
}

@test "ignores files git ignores" {
  plant .gitignore '.terraform/'
  plant environments/sample/.terraform/provider 'binary'
  chmod +x "$repository/environments/sample/.terraform/provider"
  lint
  [ "$status" -eq 0 ]
}

@test "rejects an exception whose paths match no file" {
  rm "$repository/environments/sample/legacy.tf"
  lint
  assert_violation contracts/layout/layout.yaml exceptions-current
  [[ "$output" == *"environments/sample/legacy.tf matches no file"* ]]
}

@test "rejects a package that names an environment" {
  plant packages/net-sample/values.yaml 'domain: sample'
  lint
  assert_violation packages/net-sample/values.yaml no-names
  [[ "$output" == *"names sample on line 1"* ]]
}

@test "rejects a package that names a cluster" {
  plant packages/net-sample/values.yaml 'peers: [edge]'
  lint
  assert_violation packages/net-sample/values.yaml no-names
}

@test "rejects a cluster that names an environment" {
  plant clusters/edge/values/net-sample.yaml 'target: sample'
  lint
  assert_violation clusters/edge/values/net-sample.yaml no-names
}

@test "accepts a name inside a longer word, path segment or DNS name" {
  plant packages/net-sample/values.yaml 'image: samples/edge-proxy
domain: cluster.sample'
  lint
  [ "$status" -eq 0 ]
}

@test "accepts a cluster role and a package that uses the role word" {
  plant clusters/workload/cluster.yaml 'role: trust'
  plant clusters/edge/cluster.yaml 'role: workload'
  plant packages/net-sample/values.yaml 'profile: default'
  lint
  [ "$status" -eq 0 ]
}

@test "rejects a package that names a folder called workload" {
  plant clusters/workload/cluster.yaml 'role: trust'
  plant packages/net-sample/values.yaml 'peer: workload'
  lint
  assert_violation packages/net-sample/values.yaml no-names
  [[ "$output" == *"names workload"* ]]
}

@test "rejects a root that hardcodes a cluster name" {
  plant roots/enrollment-sample/tenants.yaml 'tenants: [edge]'
  lint
  assert_violation roots/enrollment-sample/tenants.yaml roots-no-names
}

@test "rejects an IPv4 address in a package" {
  plant packages/net-sample/values.yaml 'k8sServiceHost: 10.0.0.1'
  lint
  assert_violation packages/net-sample/values.yaml no-facts
  [[ "$output" == *"IPv4 address or CIDR on line 1"* ]]
}

@test "rejects a CIDR in a cluster" {
  plant clusters/edge/values/net-sample.yaml 'podCIDR: 10.244.0.0/16'
  lint
  assert_violation clusters/edge/values/net-sample.yaml no-facts
}

@test "rejects a size in a package" {
  plant packages/net-sample/values.yaml 'memory: 512Mi'
  lint
  assert_violation packages/net-sample/values.yaml no-facts
  [[ "$output" == *"size on line 1"* ]]
}

@test "accepts the listed addresses and a port" {
  plant packages/net-sample/values.yaml 'listen: 0.0.0.0:8080
probe: 127.0.0.1
port: 6443'
  lint
  [ "$status" -eq 0 ]
}

@test "rejects an executable file in a package" {
  chmod +x "$repository/packages/net-sample/tests/values.bats"
  lint
  assert_violation packages/net-sample/tests/values.bats packages-not-executable
}

@test "rejects a package task folder without its package" {
  mkdir -p "$repository/.mise/tasks/dns-sample"
  lint
  assert_violation .mise/tasks/dns-sample task-folder-pairs-package
}

@test "rejects a module that references another layer" {
  plant modules/vm-sample/main.tf 'locals { values = file("../../packages/net-sample/values.yaml") }'
  lint
  assert_violation modules/vm-sample/main.tf modules-no-references
  [[ "$output" == *"on line 1"* ]]
}

@test "reports every violation in one run" {
  plant environments/sample/apply.sh 'true'
  plant packages/net-sample/values.yaml 'memory: 512Mi'
  lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"environments-no-code"* ]]
  [[ "$output" == *"no-facts"* ]]
}
