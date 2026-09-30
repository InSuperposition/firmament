#!/usr/bin/env bats

load stubs.bash

# The OrbStack machine tasks against the stubbed orb and orbctl, in a
# stand-in repository whose environment "sample" is the environment-spec
# sample: clusters covenant (4608 MiB) and workload (5632 MiB), 4 CPUs and
# 10 GiB each, machines sample-covenant and sample-workload.
setup() {
  setup_stubs
  MISE_PROJECT_ROOT=$(make_repository environments/sample/main.tf)
  export MISE_PROJECT_ROOT
  cp "$root_directory/contracts/environment-spec/samples/environment.yaml" "$MISE_PROJECT_ROOT/environments/sample/"
  environment_file="$MISE_PROJECT_ROOT/environments/sample/environment.yaml"
  hosts="$FIRMAMENT_STATE_HOME/environments/sample/machine-hosts.yaml"
}

orb_task() {
  local task="$1"
  shift
  usage_environment=sample run "$root_directory/.mise/tasks/orb/$task.sh"
}

@test "orb:apply creates every missing machine with its limits and records both" {
  ORB_ABSENT="sample-covenant sample-workload" orb_task apply
  [ "$status" -eq 0 ] || fail "$output"
  grep -q '^orb create --memory 4608 --cpus 4 --disk 10G ubuntu:resolute sample-covenant ' "$CALLS"
  grep -q '^orb create --memory 5632 --cpus 4 --disk 10G ubuntu:resolute sample-workload ' "$CALLS"
  [ "$(yq -r '.hosts[].name' "$hosts" | paste -sd ' ' -)" = "sample-covenant sample-workload" ]
  [ "$(yq -r '.hosts[0].ssh.user' "$hosts")" = root@sample-covenant ]
  [ "$(yq -r '.hosts[0].ssh.port' "$hosts")" = 32222 ]
}

@test "orb:apply keeps an existing machine whose limits match, and checks only new machines" {
  ORB_ABSENT=sample-workload ORB_LIMITS="4608 4 10" orb_task apply
  [ "$status" -eq 0 ] || fail "$output"
  ! grep -q '^orb create .* sample-covenant ' "$CALLS" || fail "recreated sample-covenant"
  ! grep -q '^orb -m sample-covenant ' "$CALLS" || fail "probed a kept machine"
  grep -q '^orb -m sample-workload -u root bash -s ' "$CALLS"
}

@test "orb:apply refuses an existing machine whose limits differ, before creating anything" {
  ORB_ABSENT=sample-workload ORB_LIMITS="4096 4 10" orb_task apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"sample-covenant: has memory, CPUs, disk, isolated = 4096 4 10 false; wants 4608 4 10 false"* ]]
  [[ "$output" == *"recreate it with mise run orb:destroy sample"* ]]
  ! grep -q '^orb create' "$CALLS" || fail "created a machine: $(cat "$CALLS")"
  [ ! -e "$hosts" ]
}

@test "orb:apply refuses machines whose memory exceeds OrbStack's" {
  ORB_MEMORY=8192 orb_task apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"its machines need 10240 MiB, more than the 8192 MiB OrbStack has"* ]]
  ! grep -q '^orb create' "$CALLS"
}

@test "orb:apply refuses a machine with more CPUs than OrbStack has, and lets CPUs be shared" {
  ORB_CPUS=3 orb_task apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"sample-covenant: 4 CPUs exceed the 3 OrbStack has"* ]]
  ORB_CPUS=4 ORB_ABSENT="sample-covenant sample-workload" orb_task apply
  [ "$status" -eq 0 ] || fail "4 + 4 CPUs on 4: $output"
}

@test "orb:apply refuses a cluster with more than one machine" {
  yq -i '.clusters.workload.machines += [.clusters.workload.machines[0]] | .budget.memory_mib = 20000 | .budget.disk_gib = 60' "$environment_file"
  orb_task apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster 'workload' in $environment_file lists 2 machines; OrbStack runs one machine per cluster"* ]]
  ! grep -q '^orb create' "$CALLS"
}

@test "orb:apply names every readiness requirement a new machine misses" {
  ORB_ABSENT=sample-workload ORB_LIMITS="4608 4 10" \
    UBUNTU_FACTS="id=ubuntu version_id=24.04 arch=aarch64 init=systemd cgroup=cgroup2fs btf=missing sudo=available command_curl=present command_systemctl=present" \
    orb_task apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"sample-workload: Ubuntu 26.04 is required (version_id is 24.04)"* ]]
  [[ "$output" == *"sample-workload: kernel BTF is required (btf is missing)"* ]]
  [ ! -e "$hosts" ]
}

@test "orb:plan shows what apply would do and changes nothing" {
  ORB_ABSENT=sample-workload ORB_LIMITS="4608 4 10" orb_task plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   sample-covenant"* ]]
  [[ "$output" == *"create sample-workload: 5632 MiB, 4 CPUs, 10 GiB"* ]]
  ! grep -Eq '^orb (create|delete)' "$CALLS"
}

@test "orb:destroy deletes only the machines the environment lists" {
  ORB_ABSENT=sample-workload usage_environment=sample \
    run "$root_directory/.mise/tasks/orb/destroy.sh"
  [ "$status" -eq 0 ] || fail "$output"
  run grep '^orb delete' "$CALLS"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "orb delete -f sample-covenant "* ]]
}

@test "ubuntu:verify checks every machine and names what each misses" {
  UBUNTU_FACTS="id=ubuntu version_id=26.04 arch=aarch64 init=systemd cgroup=cgroup-v1 btf=present sudo=available command_curl=present command_systemctl=present" \
    usage_environment=sample run "$root_directory/.mise/tasks/ubuntu/verify.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sample-covenant: cgroup v2 is required (cgroup is cgroup-v1)"* ]]
  [[ "$output" == *"sample-workload: cgroup v2 is required (cgroup is cgroup-v1)"* ]]
}

@test "ubuntu:verify passes on ready machines" {
  usage_environment=sample run "$root_directory/.mise/tasks/ubuntu/verify.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

fail() {
  printf '%s\n' "$*" >&2
  return 1
}
