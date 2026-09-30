# shellcheck shell=bash
# An environment's state directory on this machine: where it is, which
# worktree owns it, and the one-time moves of older layouts into it.

# Prints where an environment keeps its state and kubeconfig. mise sets
# FIRMAMENT_STATE_HOME from mise.toml [env].
state_directory() {
  printf '%s/environments/%s\n' "${FIRMAMENT_STATE_HOME:?FIRMAMENT_STATE_HOME is unset; run this through mise}" "$1"
}

# Fails on an empty state file: tofu never writes one, but an interrupted
# run can leave one, and tofu reads it as "nothing exists", so destroy would
# report success while the machine keeps running and apply would create it a
# second time.
refuse_empty_state() {
  local file="$1"
  if [[ -f "$file" && ! -s "$file" ]]; then
    fail "$file is empty, probably cut short by an interrupted run; restore it from $file.backup, or move it aside to start from no state"
  fi
}

# Moves the Flux bootstrap out of an environment's state into the bootstrap
# root's state, for environments applied while the environment root still
# held it. It runs before the environment root is initialized: that root no
# longer requires the helm and kubernetes providers, so it cannot read a
# state that still holds their resources. Does nothing without a state file
# or without a bootstrap in it. The pre-move state is kept next to it.
# Forgets the OrbStack machine and its readiness check in an environment's
# state, for environments applied while OpenTofu created the machine; the
# orb:apply task owns machines now. It runs before init: the root no longer
# requires the orbstack provider, so it cannot read a state that still holds
# the machine. The machine itself keeps running, and a notice names it. Does
# nothing without such resources. The earlier state is kept next to it.
forget_machine_state() {
  local state="$1" resources machine
  local -a modules
  [[ -s "$state/terraform.tfstate" ]] || return 0
  resources=$(tofu state list -state="$state/terraform.tfstate") || return
  mapfile -t modules < <(grep -o '^module\.\(vm_orb\|os_ubuntu\)' <<<"$resources" | sort -u)
  ((${#modules[@]})) || return 0
  machine=$(tofu output -json -state="$state/terraform.tfstate" 2>/dev/null | jq -r '.machine_name.value // empty') || machine=""
  tofu state rm -state="$state/terraform.tfstate" -backup="$state/terraform.tfstate.before-orb-tasks" \
    -- "${modules[@]}" >/dev/null || return
  printf 'The OrbStack machine %s is no longer managed here; delete it with orb delete %s once nothing uses it.\n' \
    "${machine:-(unknown)}" "${machine:-<name>}" >&2
}

move_bootstrap_state() {
  local state="$1" resources
  [[ -s "$state/terraform.tfstate" ]] || return 0
  resources=$(tofu state list -state="$state/terraform.tfstate") || return
  grep -q '^module\.bootstrap_flux\.' <<<"$resources" || return 0
  tofu state mv -state="$state/terraform.tfstate" -state-out="$state/bootstrap.tfstate" \
    -backup="$state/terraform.tfstate.before-bootstrap-root" -backup-out=- \
    module.bootstrap_flux module.bootstrap_flux >/dev/null
}

# Moves an environment's state from the singular layout
# ($FIRMAMENT_STATE_HOME/environment/<env>) to state_directory. It copies,
# compares the copy, and only then removes the original, so an interrupted
# move leaves the original untouched. It refuses when both directories
# exist, because that means two histories that must not be merged.
move_legacy_state_directory() {
  local environment="$1" state legacy
  state=$(state_directory "$environment") || return
  legacy="$FIRMAMENT_STATE_HOME/environment/$environment"
  [[ -d "$legacy" ]] || return 0
  if [[ -e "$state" ]]; then
    fail "both $legacy and $state exist; keep the one that matches the running machine and remove the other"
    return
  fi
  mkdir -p "${state%/*}"
  rm -rf "$state.partial"
  cp -Rp "$legacy" "$state.partial" || return
  diff -r "$legacy" "$state.partial" >/dev/null || fail "copy of $legacy differs from the original; nothing was removed" || return
  mv "$state.partial" "$state" || return
  rm -rf "$legacy"
  rmdir "$FIRMAMENT_STATE_HOME/environment" 2>/dev/null || true
}

# Prints the checkout this run belongs to. Every worktree of the repository
# shares one state directory and one machine per environment; a run that
# starts others from another checkout (env:e2e's baseline) exports
# FIRMAMENT_WORKTREE so they count as the same owner.
current_worktree() {
  printf '%s\n' "${FIRMAMENT_WORKTREE:-${MISE_PROJECT_ROOT:?run this through mise}}"
}

# Records this checkout as the owner of an environment's live cluster, or
# fails when another existing worktree owns it, so one worktree cannot
# rebuild or destroy the cluster another is testing. A recorded worktree
# that no longer exists does not count. FIRMAMENT_TAKE_OVER=1 claims it
# anyway.
claim_environment() {
  local environment="$1" worktree owner_file owner
  worktree=$(current_worktree) || return
  owner_file="$(state_directory "$environment")/owner"
  owner=$(cat "$owner_file" 2>/dev/null) || owner=""
  if [[ -n "$owner" && "$owner" != "$worktree" && -d "$owner" && "${FIRMAMENT_TAKE_OVER:-}" != 1 ]]; then
    fail "environment '$environment' belongs to the worktree $owner; run this there, or set FIRMAMENT_TAKE_OVER=1 to take it over"
    return
  fi
  mkdir -p "$(dirname -- "$owner_file")"
  printf '%s\n' "$worktree" >"$owner_file"
}

# Forgets the owner of an environment whose cluster was destroyed.
release_environment() {
  rm -f "$(state_directory "$1")/owner"
}
