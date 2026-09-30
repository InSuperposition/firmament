# Puts recording stand-ins for the external tools the task scripts call
# first on PATH. Each call is appended to $CALLS as
# "<tool> <arguments> | state=<TF_VAR_state_directory> branch=<TF_VAR_git_branch>".
# $real_mise keeps the real mise for tests that read the resolved
# configuration. $STATE_LIST is what `tofu state list` prints, $NODES what
# `kubectl get nodes -o name` prints, $PODS names the file whose JSON
# `kubectl get pods` prints, and $K0S_CHARTS is what `kubectl get
# charts.helm.k0sproject.io` prints; $K0S_CHARTS_ERROR makes it fail with
# that message instead. $CILIUM_VALUES is the values.yaml the cilium-values
# ConfigMap holds and $RELEASE_VALUES what `helm get values cilium` prints;
# both default to the same values, so the release runs what Flux applied.
# `tofu output` records the kubeconfig at $KUBECONFIG_OUTPUT (default
# /state/admin.kubeconfig). $NO_OUTPUTS makes it print nothing, as after a
# destroy, and
# $OUTPUT_ERROR makes it fail with that message. Calls to the fortio REST
# API print the replies fortio gave in a live run, kept in $FORTIO_REPLIES
# (its result is from a run whose server was down for 3 s, so it counts 28
# failed requests);
# $FORTIO_RUN, $FORTIO_STATUS, $FORTIO_STOP and $FORTIO_RESULT name other
# files to print instead.
# `mise tasks ls --name-only` prints $TASKS, or a fixed list without it.
# The env:doctor probes answer as a healthy host unless told otherwise:
# `orbctl status` prints $ORBCTL_STATUS (default Running), `orb info`
# reports $ORB_STATE (default running), and $HOST_DNS_ERROR, $ORB_DNS_ERROR
# and $READYZ_ERROR make the Mac's lookup, the machine's lookup and the API
# server's /readyz fail, the last with that message; the same probe by the
# machine's address (the name's relay skipped) still fails unless
# $IP_READYZ_OK is set.
# `cilium hubble port-forward` and `kubectl port-forward` listen on the local
# port they are given, as the real ones do, until the first connection closes.
setup_stubs() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  export MISE_PROJECT_ROOT="$root_directory"
  export FIRMAMENT_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export FORTIO_REPLIES="$root_directory/.mise/tests/fortio"
  export FIRMAMENT_GIT_BRANCH=feature/test
  export real_mise
  real_mise=$(command -v mise)
  stubs="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubs"
  for tool in tofu cilium hubble kubectl helm chainsaw orb orbctl dscacheutil bats mise open; do
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
      printf '{"kubeconfig_path":{"value":"%s"},"machine_name":{"value":"firmament"},"runtime_info":{"value":{"kube_proxy_replacement":"true","cilium_datapath_mode":"netkit"}}}' "\${KUBECONFIG_OUTPUT:-/state/admin.kubeconfig}"
    fi ;;
  *"state list"*) printf '%s' "\${STATE_LIST:-}" ;;
  *" get pods "*) cat "\${PODS:-/dev/null}" ;;
  *"get charts.helm.k0sproject.io"*)
    if [[ -n "\${K0S_CHARTS_ERROR:-}" ]]; then printf '%s\\n' "\$K0S_CHARTS_ERROR" >&2; exit 1; fi
    printf '%s' "\${K0S_CHARTS:-}" ;;
  *"hubble port-forward"*) exec nc -l 127.0.0.1 "\${@: -1}" >/dev/null ;;
  *" port-forward "*) local_port="\${*: -1}"; exec nc -l 127.0.0.1 "\${local_port%%:*}" >/dev/null ;;
  *"get nodes -o name"*) printf '%s' "\${NODES:-}" ;;
  *"get configmap cilium-values "*) printf '%s\\n' "\${CILIUM_VALUES-a: 1}" ;;
  *"get values cilium "*) printf '%s\\n' "\${RELEASE_VALUES-a: 1}" ;;
  *"/fortio/rest/run"*) cat "\${FORTIO_RUN:-\$FORTIO_REPLIES/run.json}" ;;
  *"/fortio/rest/status"*) cat "\${FORTIO_STATUS:-\$FORTIO_REPLIES/status.json}" ;;
  *"/fortio/rest/stop"*) cat "\${FORTIO_STOP:-\$FORTIO_REPLIES/stop.json}" ;;
  *"/fortio/data/"*) cat "\${FORTIO_RESULT:-\$FORTIO_REPLIES/result.json}" ;;
  "tasks ls --name-only") printf '%s\\n' \${TASKS:-a:verify b:test env:verify k0s:verify} ;;
  "status") printf '%s\\n' "\${ORBCTL_STATUS:-Running}" ;;
  "info "*"--format json") printf '{"record":{"name":"firmament","state":"%s"},"ip4":"192.168.139.101"}' "\${ORB_STATE:-running}" ;;
  "-q host -a name "*)
    if [[ -n "\${HOST_DNS_ERROR:-}" ]]; then exit 0; fi
    printf 'name: %s\\nip_address: 192.168.138.4\\n' "\${*: -1}" ;;
  *" getent hosts "*)
    if [[ -n "\${ORB_DNS_ERROR:-}" ]]; then exit 2; fi
    printf 'fd07:b51a:cc66:f0::fe  %s\\n' "\${*: -1}" ;;
  *"config view"*) printf 'https://firmament.orb.local:6443' ;;
  *"--server https://"*"get --raw /readyz"*)
    if [[ -n "\${READYZ_ERROR:-}" && -z "\${IP_READYZ_OK:-}" ]]; then printf '%s\\n' "\$READYZ_ERROR" >&2; exit 1; fi
    printf 'ok' ;;
  *"get --raw /readyz"*)
    if [[ -n "\${READYZ_ERROR:-}" ]]; then printf '%s\\n' "\$READYZ_ERROR" >&2; exit 1; fi
    printf 'ok' ;;
esac
exit 0
STUB
  chmod +x "$stubs/$1"
}

# Builds a stand-in repository holding the real .mise directory, each
# package's real lib/ helpers (which that package's tasks source) and an
# empty file at each given path, and prints its root.
make_repository() {
  local repository="$BATS_TEST_TMPDIR/repository" path library package
  mkdir -p "$repository"
  ln -sfn "$root_directory/.mise" "$repository/.mise"
  for library in "$root_directory"/packages/*/lib; do
    package="${library%/lib}"
    mkdir -p "$repository/packages/${package##*/}"
    ln -sfn "$library" "$repository/packages/${package##*/}/lib"
  done
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
