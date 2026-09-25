# Puts recording stand-ins for the external tools the task scripts call
# first on PATH. Each call is appended to $CALLS as
# "<tool> <arguments> | state=<TF_VAR_state_directory> branch=<TF_VAR_git_branch>".
# $real_mise keeps the real mise for tests that read the resolved
# configuration. $STATE_LIST is what `tofu state list` prints, $NODES what
# `kubectl get nodes -o name` prints, $PODS names the file whose JSON
# `kubectl get pods` prints, and $K0S_CHARTS is what `kubectl get
# charts.helm.k0sproject.io` prints; $K0S_CHARTS_ERROR makes it fail with
# that message instead. $NO_OUTPUTS makes `tofu output` print nothing, as
# after a destroy, and $OUTPUT_ERROR makes it fail with that message.
# `cilium hubble port-forward` listens on the port it is given, as the real
# one does, until the first connection closes.
setup_stubs() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  export MISE_PROJECT_ROOT="$root_directory"
  export FIRMAMENT_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export FIRMAMENT_GIT_BRANCH=feature/test
  export real_mise
  real_mise=$(command -v mise)
  stubs="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubs"
  for tool in tofu cilium kubectl chainsaw orb bats mise; do
    stub "$tool"
  done
  PATH="$stubs:$PATH"
}

# Confines git to the stand-in repositories a test builds. It clears the
# variables that pin git to one repository, which git exports to hooks, so a
# test run from a hook cannot commit, reset or push in the caller's
# repository. It ignores the user's and the system's git configuration, and
# allows only local transports, so no test can reach a real remote.
seal_git() {
  local variables
  mapfile -t variables < <(git rev-parse --local-env-vars)
  unset "${variables[@]}"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
}

stub() {
  cat >"$stubs/$1" <<STUB
#!/usr/bin/env bash
printf '%s %s | state=%s branch=%s\n' "$1" "\$*" "\${TF_VAR_state_directory:-}" "\${TF_VAR_git_branch:-}" >>"\$CALLS"
case "\$*" in
  *"output -json"*)
    if [[ -n "\${OUTPUT_ERROR:-}" ]]; then printf '%s\\n' "\$OUTPUT_ERROR" >&2; exit 1; fi
    if [[ -n "\${NO_OUTPUTS:-}" ]]; then printf '{}'; else
      printf '{"kubeconfig_path":{"value":"/state/admin.kubeconfig"},"machine_name":{"value":"firmament"}}'
    fi ;;
  *"state list"*) printf '%s' "\${STATE_LIST:-}" ;;
  *" get pods "*) cat "\${PODS:-/dev/null}" ;;
  *"get charts.helm.k0sproject.io"*)
    if [[ -n "\${K0S_CHARTS_ERROR:-}" ]]; then printf '%s\\n' "\$K0S_CHARTS_ERROR" >&2; exit 1; fi
    printf '%s' "\${K0S_CHARTS:-}" ;;
  *"hubble port-forward"*) exec nc -l 127.0.0.1 "\${@: -1}" >/dev/null ;;
  *"get nodes -o name"*) printf '%s' "\${NODES:-}" ;;
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

# Builds a stand-in repository like make_repository, commits it on the given
# branch, pushes that branch to a bare origin and fetches it, and prints its
# root. The checkout is clean and equal to origin, as env:e2e requires.
make_pushed_repository() {
  local branch="$1" repository origin="$BATS_TEST_TMPDIR/origin.git"
  shift
  repository=$(make_repository "$@")
  git init -q --bare "$origin"
  git -C "$repository" init -q -b "$branch"
  git -C "$repository" remote add origin "$origin"
  commit_and_push "$repository" "$branch" start
  printf '%s\n' "$repository"
}

# Commits everything in a repository and pushes it to origin as the given
# branch, then fetches.
commit_and_push() {
  local repository="$1" branch="$2" message="$3"
  git -C "$repository" add -A
  git -C "$repository" -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m "$message"
  git -C "$repository" push -q origin "HEAD:refs/heads/$branch"
  git -C "$repository" fetch -q origin
}
