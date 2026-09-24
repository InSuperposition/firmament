# Puts recording stand-ins for the external tools the task scripts call
# first on PATH. Each call is appended to $CALLS as
# "<tool> <arguments> | state=<TF_VAR_state_directory> branch=<TF_VAR_git_branch>".
# $real_mise keeps the real mise for tests that read the resolved
# configuration. $STATE_LIST is what `tofu state list` prints, $NODES what
# `kubectl get nodes -o name` prints, $PODS names the file whose JSON
# `kubectl get pods` prints, and $K0S_CHARTS is what `kubectl get
# charts.helm.k0sproject.io` prints; $K0S_CHARTS_ERROR makes it fail with
# that message instead.
setup_stubs() {
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

stub() {
  cat >"$stubs/$1" <<STUB
#!/usr/bin/env bash
printf '%s %s | state=%s branch=%s\n' "$1" "\$*" "\${TF_VAR_state_directory:-}" "\${TF_VAR_git_branch:-}" >>"\$CALLS"
case "\$*" in
  *"output -raw kubeconfig_path"*) printf '/state/admin.kubeconfig' ;;
  *"output -raw machine_name"*) printf 'firmament' ;;
  *"state list"*) printf '%s' "\${STATE_LIST:-}" ;;
  *" get pods "*) cat "\${PODS:-/dev/null}" ;;
  *"get charts.helm.k0sproject.io"*)
    if [[ -n "\${K0S_CHARTS_ERROR:-}" ]]; then printf '%s\\n' "\$K0S_CHARTS_ERROR" >&2; exit 1; fi
    printf '%s' "\${K0S_CHARTS:-}" ;;
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
