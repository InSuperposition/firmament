# shellcheck shell=bash
# OrbStack machines from an environment's environment.yaml: one machine per
# cluster, named <environment>-<cluster>, created and deleted with the orb
# CLI. OrbStack itself is the record of what exists; there is no state file.

# Prints the path of an environment's environment.yaml, or fails when it
# has none.
environment_file() {
  local file
  file="$(environment_directory "$1")/environment.yaml" || return
  [[ -f "$file" ]] || fail "environment '$1' has no environment.yaml" || return
  printf '%s\n' "$file"
}

# Prints one "<machine> <cluster> <memory MiB> <cpus> <disk GiB>" line per
# cluster. OrbStack runs one machine per cluster, so a cluster that lists
# more fails.
environment_machines() {
  local environment="$1" file
  file=$(environment_file "$environment") || return
  yq -r '.clusters // {} | to_entries[] | [.key, (.value.machines | length),
    .value.machines[0].memory_mib, .value.machines[0].cpus, .value.machines[0].disk_gib] | @tsv' "$file" |
    while IFS=$'\t' read -r cluster count memory cpus disk; do
      if [[ "$count" != 1 ]]; then
        fail "cluster '$cluster' in $file lists $count machines; OrbStack runs one machine per cluster"
        return
      fi
      printf '%s-%s %s %s %s %s\n' "$environment" "$cluster" "$cluster" "$memory" "$cpus" "$disk"
    done
}

# Prints "<memory MiB> <cpus> <disk GiB> <isolated>" for an existing
# machine, or nothing when OrbStack has no machine of that name.
machine_limits() {
  local info
  info=$(orb info "$1" --format json 2>/dev/null) || return 0
  jq -r '.record.config | [.memory_limit_mib, .cpu_limit,
    ((.disk_limit_bytes // 0) / 1073741824 | floor), (.isolated // false)] | map(tostring) | join(" ")' <<<"$info"
}

# Fails when the environment's machines cannot fit OrbStack's own limits:
# their memory summed above OrbStack's memory, or one machine with more
# CPUs than OrbStack has. CPU limits are ceilings the machines may share.
check_orbstack_budget() {
  local environment="$1" machines global_memory global_cpus total=0 status=0
  local machine cluster memory cpus disk
  machines=$(environment_machines "$environment") || return
  global_memory=$(orbctl config get memory_mib) || return
  global_cpus=$(orbctl config get cpu) || return
  while read -r machine cluster memory cpus disk; do
    [[ -n "$machine" ]] || continue
    total=$((total + memory))
    if ((cpus > global_cpus)); then
      printf '%s: %s CPUs exceed the %s OrbStack has\n' "$machine" "$cpus" "$global_cpus" >&2
      status=1
    fi
  done <<<"$machines"
  if ((total > global_memory)); then
    printf "environment '%s': its machines need %s MiB, more than the %s MiB OrbStack has\n" \
      "$environment" "$total" "$global_memory" >&2
    status=1
  fi
  return "$status"
}

# Prints what apply_machines would do, one line per machine: create, keep,
# or differs (with what differs). Changes nothing.
plan_machines() {
  local machines machine cluster memory cpus disk limits wanted
  machines=$(environment_machines "$1") || return
  while read -r machine cluster memory cpus disk; do
    [[ -n "$machine" ]] || continue
    limits=$(machine_limits "$machine")
    wanted="$memory $cpus $disk false"
    if [[ -z "$limits" ]]; then
      printf 'create %s: %s MiB, %s CPUs, %s GiB\n' "$machine" "$memory" "$cpus" "$disk"
    elif [[ "$limits" == "$wanted" ]]; then
      printf 'keep   %s\n' "$machine"
    else
      printf 'differs %s: has memory, CPUs, disk, isolated = %s; wants %s\n' "$machine" "$limits" "$wanted"
    fi
  done <<<"$machines"
}

# Creates every machine the environment lists that does not exist yet and
# checks each new one is ready for k0s. An existing machine is kept when
# its limits match and fails the run when they differ: a machine is
# recreated on purpose (orb:destroy), never silently.
apply_machines() {
  local environment="$1" plan line status=0 machines machine cluster memory cpus disk
  machines=$(environment_machines "$environment") || return
  check_orbstack_budget "$environment" || return
  plan=$(plan_machines "$environment") || return
  while IFS= read -r line; do
    [[ "$line" == differs* ]] || continue
    printf '%s\n' "${line#differs }" >&2
    status=1
  done <<<"$plan"
  if ((status)); then
    fail "an existing machine differs from environment.yaml; recreate it with mise run orb:destroy $environment, then apply"
    return
  fi
  while read -r machine cluster memory cpus disk; do
    [[ -n "$machine" ]] || continue
    grep -qx "create $machine:.*" <<<"$plan" || continue
    orb create --memory "$memory" --cpus "$cpus" --disk "${disk}G" ubuntu:resolute "$machine" >/dev/null || return
    check_ubuntu_ready "$machine" || return
  done <<<"$machines"
  write_machine_hosts "$environment"
}

# Deletes the machines the environment lists that exist, and forgets their
# machine-hosts file. Machines it does not list are never touched.
destroy_machines() {
  local environment="$1" machines machine rest state
  state=$(state_directory "$environment") || return
  machines=$(environment_machines "$environment") || return
  while read -r machine rest; do
    [[ -n "$machine" ]] || continue
    [[ -n "$(machine_limits "$machine")" ]] || continue
    orb delete -f "$machine" >/dev/null || return
  done <<<"$machines"
  rm -f "$state/machine-hosts.yaml"
}

# Writes the machine-hosts contract for the environment's machines to its
# state directory, and validates it before anything reads it. Every machine
# is reached through OrbStack's SSH proxy as root@<machine>.
write_machine_hosts() {
  local environment="$1" machines state file partial machine rest address hosts=""
  state=$(state_directory "$environment") || return
  machines=$(environment_machines "$environment") || return
  file="$state/machine-hosts.yaml"
  partial="$state/machine-hosts.partial.yaml"
  while read -r machine rest; do
    [[ -n "$machine" ]] || continue
    address=$(orb info "$machine" --format json | jq -r '.ip4 // empty') || return
    [[ -n "$address" ]] || fail "$machine has no IPv4 address" || return
    hosts+=$(jq -cn --arg name "$machine" --arg address "$address" \
      '{name: $name, address: $address, ssh: {address: "127.0.0.1", port: 32222, user: "root@\($name)", key: "orbstack-ssh"}, role: "controller+worker"}')
    hosts+=$'\n'
  done <<<"$machines"
  mkdir -p "$state"
  jq -s '{hosts: .}' <<<"$hosts" | yq -P '.' >"$partial" || return
  (cd "${MISE_PROJECT_ROOT:?}/contracts" && cue vet -c -d '#MachineHosts' ./machine-hosts "$partial") || return
  mv "$partial" "$file"
}

# Fails unless every machine the environment lists runs with the limits it
# asks for, read where they take effect: memory and CPUs from the machine's
# own cgroup (memory.max, cpu.max), not from free or nproc, which show the
# shared OrbStack VM; the disk limit from OrbStack's configuration.
verify_machines() {
  local machines machine cluster memory cpus disk limits cgroup status=0
  machines=$(environment_machines "$1") || return
  while read -r machine cluster memory cpus disk; do
    [[ -n "$machine" ]] || continue
    limits=$(machine_limits "$machine")
    if [[ -z "$limits" ]]; then
      printf '%s: no such machine; run mise run orb:apply %s\n' "$machine" "$1" >&2
      status=1
      continue
    fi
    cgroup=$(orb -m "$machine" -u root cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max | paste -sd ' ' -) || {
      printf '%s: cannot read its cgroup limits\n' "$machine" >&2
      status=1
      continue
    }
    if [[ "$cgroup" != "$((memory * 1048576)) $((cpus * 100000)) 100000" ]]; then
      printf '%s: cgroup memory.max and cpu.max are %s; want %s MiB and %s CPUs\n' "$machine" "$cgroup" "$memory" "$cpus" >&2
      status=1
    fi
    if [[ "$(cut -d ' ' -f 3 <<<"$limits")" != "$disk" ]]; then
      printf '%s: disk limit is %s GiB; want %s GiB\n' "$machine" "$(cut -d ' ' -f 3 <<<"$limits")" "$disk" >&2
      status=1
    fi
  done <<<"$machines"
  return "$status"
}
