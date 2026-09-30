# shellcheck shell=bash
# Helpers shared by the mise file tasks in .mise/tasks. Source this file; it
# loads every file in .mise/lib, then clears the git variables a hook
# exports (forget_git_repository_env). Package helpers live with their
# package and are sourced by that package's tasks.

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# shellcheck source=lib/git.sh
source "${BASH_SOURCE[0]%/*}/lib/git.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/lib/state.sh"
# shellcheck source=lib/environment.sh
source "${BASH_SOURCE[0]%/*}/lib/environment.sh"
# shellcheck source=lib/tofu.sh
source "${BASH_SOURCE[0]%/*}/lib/tofu.sh"
# shellcheck source=lib/flux.sh
source "${BASH_SOURCE[0]%/*}/lib/flux.sh"
# shellcheck source=lib/chainsaw.sh
source "${BASH_SOURCE[0]%/*}/lib/chainsaw.sh"
# shellcheck source=lib/waits.sh
source "${BASH_SOURCE[0]%/*}/lib/waits.sh"

forget_git_repository_env
