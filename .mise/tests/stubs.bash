# Puts recording stand-ins for the external tools the task scripts call
# first on PATH. Each call is appended to $CALLS as
# "<tool> <arguments> | state=<TF_VAR_state_directory>". $real_mise keeps
# the real mise for tests that read the resolved configuration.
setup_stubs() {
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  export MISE_PROJECT_ROOT="$root_directory"
  export FIRMAMENT_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export real_mise
  real_mise=$(command -v mise)
  stubs="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubs"
  for tool in tofu cilium kubectl orb bats mise; do
    stub "$tool"
  done
  PATH="$stubs:$PATH"
}

stub() {
  cat >"$stubs/$1" <<STUB
#!/usr/bin/env bash
printf '%s %s | state=%s\n' "$1" "\$*" "\${TF_VAR_state_directory:-}" >>"\$CALLS"
case "\$*" in
  *"output -raw kubeconfig_path"*) printf '/state/admin.kubeconfig' ;;
  *"output -raw machine_name"*) printf 'firmament' ;;
  *"get charts.helm.k0sproject.io -o json"*) cat "\${CHARTS:-/dev/null}" ;;
  "tasks ls --name-only") printf '%s\\n' a:verify b:test k0s:verify ;;
esac
exit 0
STUB
  chmod +x "$stubs/$1"
}

# Builds a stand-in repository holding the real .mise directory and an empty
# file at each given path, and prints its root.
make_repository() {
  local repository="$BATS_TEST_TMPDIR/repository" path
  mkdir -p "$repository"
  ln -sfn "$root_directory/.mise" "$repository/.mise"
  for path in "$@"; do
    mkdir -p "$repository/$(dirname -- "$path")"
    : >"$repository/$path"
  done
  printf '%s\n' "$repository"
}
