# shellcheck shell=bash
# Helpers shared by the mise file tasks in .mise/tasks. Source this file;
# apart from forget_git_repository_env below, it defines functions only.

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
forget_git_repository_env

fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# Prints the OpenTofu root directory of an environment, or fails when the
# environment does not exist.
environment_directory() {
  local environment="$1"
  local directory="${MISE_PROJECT_ROOT:?run this through mise}/environment/$environment"
  if [[ ! -d "$directory" ]]; then
    fail "unknown environment '$environment': $directory does not exist"
    return
  fi
  printf '%s\n' "$directory"
}

# Prints where an environment keeps its state and kubeconfig. mise sets
# FIRMAMENT_STATE_HOME from mise.toml [env].
state_directory() {
  printf '%s/environment/%s\n' "${FIRMAMENT_STATE_HOME:?FIRMAMENT_STATE_HOME is unset; run this through mise}" "$1"
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

# Prints the revision Flux reports once it has applied a branch at the tip
# origin had when last fetched.
flux_revision() {
  local sha
  sha=$(remote_branch_sha "$1") || return
  printf 'refs/heads/%s@sha1:%s\n' "$1" "$sha"
}

# Runs tofu in an environment's root, telling it where its state directory
# is and which branch Flux follows. Every other input belongs to the
# environment's own configuration.
tofu_in_environment() {
  local environment="$1"
  shift
  local directory state branch
  directory=$(environment_directory "$environment") || return
  state=$(state_directory "$environment") || return
  branch=$(git_branch) || return
  TF_VAR_state_directory="$state" TF_VAR_git_branch="$branch" tofu -chdir="$directory" "$@"
}

# Points an environment's OpenTofu backend at its state file. Providers
# install only as the committed lock file records them.
init_environment() {
  local environment="$1"
  local state
  environment_directory "$environment" >/dev/null || return
  state=$(state_directory "$environment") || return
  mkdir -p "$state"
  tofu_in_environment "$environment" init -input=false -reconfigure -lockfile=readonly \
    -backend-config="path=$state/terraform.tfstate" >/dev/null
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

# Initializes an OpenTofu root or module without a backend, for checks that
# never read or write state. Providers install only as the committed lock
# file records them.
init_offline() {
  tofu -chdir="$1" init -backend=false -input=false -reconfigure -lockfile=readonly >/dev/null
}

# Prints each module or environment directory that holds an OpenTofu test
# suite (tests/*.tftest.hcl), once, in sorted order.
tofu_test_directories() {
  local suite
  for suite in "${MISE_PROJECT_ROOT:?run this through mise}"/{modules,environment}/*/tests/*.tftest.hcl; do
    if [[ -e "$suite" ]]; then
      dirname -- "$(dirname -- "$suite")"
    fi
  done | sort -u
}

# Prints one output from an environment's state, or nothing when the state
# has no value for it, as after a destroy. Fails only when the state cannot
# be read. It reads the JSON form: with no outputs, `tofu output -raw` prints
# a warning to stdout and still exits 0, while the JSON form prints an empty
# object.
environment_output_or_empty() {
  local outputs
  outputs=$(tofu_in_environment "$1" output -json) || return
  jq -r --arg name "$2" '.[$name].value // empty' <<<"$outputs"
}

# Prints one output from an environment's state. Fails when the state has no
# value for it, as after a destroy, or cannot be read.
environment_output() {
  local value
  value=$(environment_output_or_empty "$1" "$2") || return
  if [[ -z "$value" ]]; then
    fail "environment '$1' has no $2 in its state; apply it first"
    return
  fi
  printf '%s' "$value"
}

# Prints the kubeconfig path recorded in an environment's state.
environment_kubeconfig() {
  environment_output "$1" kubeconfig_path
}

# Runs chainsaw against an environment's cluster. chainsaw has no kubeconfig
# flag; it reads KUBECONFIG, set here from the path recorded in state.
chainsaw_in_environment() {
  local environment="$1"
  shift
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$environment") || return
  KUBECONFIG="$kubeconfig" chainsaw "$@"
}

# Prints the OrbStack and guest kernel versions an environment's machine
# runs on. Both sit outside what this repository pins, so live runs record
# them.
platform_versions() {
  local machine
  machine=$(environment_output "$1" machine_name) || return
  printf 'OrbStack: %s\n' "$(orb version | head -n 1)"
  printf 'kernel: %s\n' "$(orb -m "$machine" uname -r)"
}

# Prints one sorted "namespace/pod uid container-ids restarts" line for each
# pod an identity list selects. Each list line is "<namespace> <selector>".
# Two snapshots that match mean the same pods kept running, with no
# container restarted or replaced. A line that selects no pod fails, since
# two empty snapshots would match without checking anything.
workload_identities() {
  local kubeconfig="$1" list="$2" namespace selector identities
  while read -r namespace selector; do
    [[ -n "$namespace" && "$namespace" != \#* ]] || continue
    identities=$(kubectl --kubeconfig "$kubeconfig" -n "$namespace" get pods -l "$selector" -o json |
      jq -r '.items[] | [
          .metadata.namespace + "/" + .metadata.name,
          .metadata.uid,
          ([.status.containerStatuses[]?.containerID] | sort | join(",")),
          ([.status.containerStatuses[]?.restartCount] | add // 0)
        ] | @tsv') || return
    if [[ -z "$identities" ]]; then
      fail "$namespace $selector selects no pod"
      return
    fi
    printf '%s\n' "$identities"
  done <"$list" | sort
}

# Prints the stand-in runtime values in .mise/flux-test-values.env as
# KEY=value lines, without comments or blank lines.
flux_test_values() {
  grep -Ev '^[[:space:]]*(#|$)' "${MISE_PROJECT_ROOT:?run this through mise}/.mise/flux-test-values.env"
}

# Renders what Flux applies from an environment's flux directory, with the
# stand-in values in place of the runtime values OpenTofu computes. Fails on
# a variable left without a value.
render_flux_build() {
  local -a values
  mapfile -t values < <(flux_test_values)
  kubectl kustomize "$1" | env "${values[@]}" flux envsubst --strict
}

# Removes the Flux bootstrap from an environment's state, so destroy works
# when the API server is already gone: its objects live in the cluster and
# go with the machine. Does nothing without a state file or a bootstrap in
# it. state rm writes its backup into the working directory unless told
# otherwise; the state directory keeps it next to the state, out of Git.
forget_bootstrap() {
  local environment="$1" state resources
  state=$(state_directory "$environment") || return
  [[ -f "$state/terraform.tfstate" ]] || return 0
  resources=$(tofu_in_environment "$environment" state list) || return
  grep -q '^module\.bootstrap_flux\.' <<<"$resources" || return 0
  tofu_in_environment "$environment" state rm \
    -backup="$state/terraform.tfstate.bootstrap.backup" module.bootstrap_flux
}

# Fails when the environment's cluster has Helm charts that k0s installs.
# k0s uninstalls a chart once it leaves its configuration, and this
# configuration installs none, so applying over such a cluster would remove
# its Cilium. Passes when the state records no cluster yet; fails when the
# state cannot be read or a recorded cluster cannot answer, since either
# says nothing about its charts.
refuse_k0s_charts() {
  local kubeconfig charts errors error_text
  kubeconfig=$(environment_output_or_empty "$1" kubeconfig_path) || return
  if [[ -z "$kubeconfig" ]]; then
    return 0
  fi
  errors=$(mktemp)
  if ! charts=$(kubectl --kubeconfig "$kubeconfig" get charts.helm.k0sproject.io -A -o name --request-timeout=10s 2>"$errors"); then
    error_text=$(cat "$errors")
    rm -f "$errors"
    fail "cannot tell whether k0s installs Helm charts on this cluster:"$'\n'"$error_text"$'\n'"Start the machine, or rebuild it: mise run --yes env:destroy $1, then mise run env:apply $1"
    return
  fi
  rm -f "$errors"
  if [[ -n "$charts" ]]; then
    fail "k0s still installs Helm charts on this cluster, and applying would uninstall them:"$'\n'"$charts"$'\n'"Rebuild it instead: mise run --yes env:destroy $1, then mise run env:apply $1"
  fi
}

# Waits until the node the cluster just created has registered with the API
# server. Retries while k0s starts the API server, whereas kubectl wait fails
# on a node that does not exist yet.
wait_for_node() {
  local kubeconfig="$1" timeout="${2:-300}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout))
  until [[ -n "$(kubectl --kubeconfig "$kubeconfig" get nodes -o name 2>/dev/null)" ]]; do
    if ((SECONDS >= deadline)); then
      fail "no node registered with the API server within ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
}

# Prints where cilium:traffic-start keeps what cilium:traffic-check reads:
# the fortio run, the conn-disrupt restart counts and the Cilium agent pods.
traffic_directory() {
  local state
  state=$(state_directory "$1") || return
  printf '%s/traffic\n' "$state"
}

# Sends one request to the fortio REST API in the traffic-probe client pod
# and prints the reply body. The last argument is the path under /fortio/,
# the ones before it go to `fortio curl`. fortio curl writes the reply
# headers to stderr, so stderr is shown only when the call fails.
fortio_rest() {
  local kubeconfig="$1" errors reply url error_text
  shift
  url="http://localhost:8080/fortio/${*: -1}"
  errors=$(mktemp)
  if ! reply=$(kubectl --kubeconfig "$kubeconfig" -n traffic-probe exec deployment/fortio-client -- \
    fortio curl -quiet -timeout 30s "${@:1:$#-1}" "$url" 2>"$errors"); then
    error_text=$(cat "$errors")
    rm -f "$errors"
    fail "fortio did not answer $url:"$'\n'"$error_text"
    return
  fi
  rm -f "$errors"
  printf '%s\n' "$reply"
}

# Prints the pod identities of the Cilium agents, as workload_identities
# does; two snapshots that differ mean an agent restarted in between.
cilium_agent_identities() {
  workload_identities "$1" <(printf 'kube-system k8s-app=cilium\n')
}

# Prints the state fortio reports for a run: unknown, pending, running,
# stopping or stopped, the number itself for a state fortio does not name,
# or nothing when fortio no longer knows the run.
fortio_run_state() {
  fortio_rest "$1" "rest/status?runid=$2" |
    jq -r --arg run "$2" '.Statuses[$run].State // empty
      | if type == "number" and . >= 0 and . < 5 and . == floor
        then ["unknown", "pending", "running", "stopping", "stopped"][.]
        else tostring end'
}

# Prints the YAML values on stdin as one line of JSON with sorted keys, so
# two documents holding the same values print the same text.
canonical_values() {
  yq -o=json -I=0 'sort_keys(..)'
}

# Succeeds when the deployed cilium release runs the values in the
# cilium-values ConfigMap, as Flux last applied it. A HelmRelease reports
# Ready for its previous values until helm-controller notices the change.
cilium_values_deployed() {
  local kubeconfig="$1" wanted deployed
  wanted=$(kubectl --kubeconfig "$kubeconfig" -n flux-system get configmap cilium-values \
    -o jsonpath='{.data.values\.yaml}' | canonical_values) || return
  deployed=$(helm --kubeconfig "$kubeconfig" -n kube-system get values cilium -o yaml | canonical_values) || return
  [[ -n "$wanted" && "$wanted" != null && "$wanted" == "$deployed" ]]
}

# Waits until the cilium release runs the values Flux applied.
wait_for_cilium_values() {
  local kubeconfig="$1" timeout="${2:-600}" interval="${3:-5}"
  local deadline=$((SECONDS + timeout))
  until cilium_values_deployed "$kubeconfig" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      fail "the cilium release does not run the values in the cilium-values ConfigMap after ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
}

# Waits until the cluster is healthy after an apply. The first Cilium wait
# retries while k0s restarts the API server, whereas kubectl fails on the
# first refused connection. Then the FluxInstance and the Cilium release
# must be Ready, and Cilium is checked again in case helm-controller rolled
# its pods meanwhile. It does not wait for Flux to apply the pushed commit;
# env:verify does, and cilium:verify then checks the release it deploys.
wait_for_cluster() {
  local kubeconfig
  kubeconfig=$(environment_kubeconfig "$1") || return
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=10m
  kubectl --kubeconfig "$kubeconfig" -n flux-system wait --for=condition=Ready helmrelease/cilium --timeout=10m
  cilium --kubeconfig "$kubeconfig" status --wait --wait-duration=10m --interactive=false
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready node --all --timeout=5m
}

# Waits until something listens on a local TCP port that a background
# process, such as a port-forward, is opening. Fails when that process exits
# first or the port stays closed for the given number of seconds.
wait_for_local_port() {
  local pid="$1" port="$2" timeout="$3"
  local deadline=$((SECONDS + timeout))
  until (: >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "the process that should listen on local port $port exited"
      return 1
    fi
    if ((SECONDS >= deadline)); then
      fail "nothing listens on local port $port after ${timeout}s"
      return 1
    fi
    sleep 0.2
  done
}
