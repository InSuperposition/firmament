# shellcheck shell=bash
# Git helpers: the branch Flux follows and its tip on origin.

# Clears the variables that pin git to one repository (GIT_DIR,
# GIT_WORK_TREE, GIT_INDEX_FILE and the rest git lists). Git exports them to
# hooks, with absolute paths in a linked worktree, so a task started from a
# hook would otherwise aim every git command it runs, including the clones
# tofu makes to fetch modules, at the caller's repository and index. Tasks
# find their repository from the working directory instead.
forget_git_repository_env() {
  local variables
  mapfile -t variables < <(git rev-parse --local-env-vars)
  unset "${variables[@]}"
}

# Fails unless a branch name is one Git accepts and uses only letters,
# digits and . _ / -, since the Flux bootstrap Job interpolates it into a
# shell command.
check_branch_name() {
  if [[ ! "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || ! git check-ref-format --branch "$1" >/dev/null 2>&1; then
    fail "invalid branch name '$1': use a name Git accepts, made of letters, digits and . _ / - only"
  fi
}

# Prints the branch of this repository that Flux follows: FIRMAMENT_GIT_BRANCH
# when the caller sets it, otherwise the checked-out branch. A detached HEAD
# names no branch, so it fails instead of guessing one.
git_branch() {
  local branch="${FIRMAMENT_GIT_BRANCH:-}"
  if [[ -z "$branch" ]]; then
    branch=$(git -C "${MISE_PROJECT_ROOT:?run this through mise}" symbolic-ref --short -q HEAD) ||
      fail "HEAD is detached; set FIRMAMENT_GIT_BRANCH to the branch Flux should follow" || return
  fi
  check_branch_name "$branch" || return
  printf '%s\n' "$branch"
}

# Prints the commit a branch pointed at on origin when it was last fetched.
remote_branch_sha() {
  git -C "${MISE_PROJECT_ROOT:?run this through mise}" rev-parse --verify -q "refs/remotes/origin/$1^{commit}" ||
    fail "origin/$1 does not exist; push the branch first"
}
