# Puts recording stand-ins for the external tools the task scripts call
# first on PATH. Each call is appended to $CALLS as
# "<tool> <arguments> | state=<TF_VAR_state_directory> branch=<TF_VAR_git_branch>".
# $real_mise keeps the real mise for tests that read the resolved
# configuration. $NODES is what
# `kubectl get nodes -o name` prints, $PODS names the file whose JSON
# `kubectl get pods` prints, and $K0S_CHARTS is what `kubectl get
# charts.helm.k0sproject.io` prints; $K0S_CHARTS_ERROR makes it fail with
# that message instead. $CILIUM_VALUES is the values.yaml the cilium-values
# ConfigMap holds and $RELEASE_VALUES what `helm get values cilium` prints;
# both default to the same values, so the release runs what Flux applied.
# The local environment's contract files record a machine and a cluster
# (record_contracts below). Calls to the fortio REST
# API print the replies fortio gave in a live run, kept in $FORTIO_REPLIES
# (its result is from a run whose server was down for 3 s, so it counts 28
# failed requests);
# $FORTIO_RUN, $FORTIO_STATUS, $FORTIO_STOP and $FORTIO_RESULT name other
# files to print instead.
# `tofu state list` prints $TOFU_STATE_LIST. k0sctl is its own stand-in: `k0sctl
# apply` fails with $K0SCTL_APPLY_ERROR or sleeps $K0SCTL_APPLY_SLEEP seconds
# when set, and `k0sctl kubeconfig` prints a kubeconfig, or half of one and
# fails with $K0SCTL_KUBECONFIG_ERROR when set.
# `kubectl run ... nc -z` in a consumer namespace prints
# $NP_ALLOWED (default exit=0), and in default $NP_PROVIDER_DENIED (default
# exit=1); the openbao namespace has one pod-network pod, 10.0.0.5.
# `kubectl run ... nslookup` prints $NP_RESOLVED (default exit=0); a pod-network
# hubble-relay pod has IP 10.0.0.7. A pod in the tenant namespace cv has IP
# 10.0.0.9, and `kubectl run` there prints $NP_TENANT_API (default: timed out).
# `kubectl exec ... hubble observe` prints one flow, or nothing for the verdict
# named in $NP_NO_FLOW (DROPPED or FORWARDED).
# `kubectl get ocirepositories` lists $OCI_SOURCES (default: one signed source
# named cv), and `kubectl apply -f -` appends what it reads to
# $BATS_TEST_TMPDIR/applied. `kubectl wait` on a chart source fails when its
# arguments contain $TV_FAIL. The holder pod of the temporary namespace has IP
# 10.0.0.12, and `kubectl exec holder` prints $TV_LISTENING (default exit=0).
# `kubectl get` of the traffic permit fails when $PERMIT_MISSING is set, and of
# the namespace cilium-test-1 when $CILIUM_TEST_NAMESPACE_MISSING is set.
# `mise tasks ls --name-only` prints $TASKS, or a fixed list without it.
# The env:doctor probes answer as a healthy host unless told otherwise:
# `orbctl status` prints $ORBCTL_STATUS (default Running), `orb info`
# reports $ORB_STATE (default running), and $HOST_DNS_ERROR, $ORB_DNS_ERROR
# and $READYZ_ERROR make the Mac's lookup, the machine's lookup and the API
# server's /readyz fail, the last with that message; the same probe from
# inside the machine still fails unless $MACHINE_READYZ_OK is set.
# `cilium hubble port-forward` and `kubectl port-forward` listen on the local
# port they are given, as the real ones do, until the first connection closes.
setup_stubs() {
  seal_git
  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)
  export MISE_PROJECT_ROOT="$root_directory"
  export FIRMAMENT_STATE_HOME="$BATS_TEST_TMPDIR/state"
  unset MISE_ENV TF_VAR_state_directory
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
  stub_k0sctl
  PATH="$stubs:$PATH"
  record_contracts
}

# The k0sctl stand-in: records each call like the other tools and plays the
# parts of apply and kubeconfig a test can ask to fail or hang.
stub_k0sctl() {
  link_shared_stub k0sctl && return
  cat >"$stubs/k0sctl" <<'STUB'
#!/usr/bin/env bash
printf 'k0sctl %s | state=%s branch=%s\n' "$*" "${TF_VAR_state_directory:-}" "${TF_VAR_git_branch:-}" >>"$CALLS"
case "$1" in
  apply)
    if [[ -n "${K0SCTL_APPLY_SLEEP:-}" ]]; then exec sleep "$K0SCTL_APPLY_SLEEP"; fi
    if [[ -n "${K0SCTL_APPLY_ERROR:-}" ]]; then printf '%s\n' "$K0SCTL_APPLY_ERROR" >&2; exit 1; fi
    ;;
  kubeconfig)
    printf 'apiVersion: v1\nkind: Config\n'
    if [[ -n "${K0SCTL_KUBECONFIG_ERROR:-}" ]]; then printf '%s\n' "$K0SCTL_KUBECONFIG_ERROR" >&2; exit 1; fi
    printf 'clusters: []\n'
    ;;
esac
exit 0
STUB
  chmod +x "$stubs/k0sctl"
  share_stub k0sctl
}

# Writes the contract files a healthy local environment's roots leave in its
# state directory: machine-hosts.yaml for a machine named firmament and
# cluster-access.yaml for a cluster whose kubeconfig is at $1 (default
# /state/admin.kubeconfig), plus the kubeconfig and k0sctl.yaml files a built
# cluster leaves in the state directory. Tasks read these instead of running tofu.
record_contracts() {
  local state="$FIRMAMENT_STATE_HOME/environments/local" kubeconfig="${1:-/state/admin.kubeconfig}"
  mkdir -p "$state"
  printf 'name: firmament\ndns_name: firmament.orb.local\nip_address: 192.168.139.10\nssh: {address: 127.0.0.1, port: 32222, user: root@firmament, key_path: /keys/id_ed25519}\n' \
    >"$state/machine-hosts.yaml"
  printf 'kubeconfig_path: %s\nruntime_info: {kube_proxy_replacement: "true", cilium_datapath_mode: netkit}\n' "$kubeconfig" \
    >"$state/cluster-access.yaml"
  : >"$state/admin.kubeconfig"
  printf 'spec:\n  k0s:\n    config:\n      spec:\n        api: {externalAddress: 192.168.139.10, port: 6443}\n' \
    >"$state/k0sctl.yaml"
}

# Removes one contract file of the local environment, as destroying the
# root that wrote it does: machine-hosts.yaml or cluster-access.yaml (which
# also takes the kubeconfig the cluster-access contract points at).
forget_contract() {
  rm -f "$FIRMAMENT_STATE_HOME/environments/local/$1"
  if [[ "$1" == cluster-access.yaml ]]; then
    rm -f "$FIRMAMENT_STATE_HOME/environments/local/admin.kubeconfig"
  fi
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

# Stand-ins are written once per bats run and linked into each test's
# directory: macOS checks a script the first time it runs, about 200 ms, and a
# stand-in written anew for every test paid that in every test. The shared
# copies are read-only, so a test that rewrites one must first call own_stub,
# which swaps the link for a private copy; without it the write fails.
shared_stubs() {
  printf '%s/stubs\n' "$BATS_RUN_TMPDIR"
}

# Links the shared stand-in $1 into the test's directory and succeeds, or
# fails when no test has written it yet.
link_shared_stub() {
  [[ -e "$(shared_stubs)/$1" ]] || return 1
  ln -s "$(shared_stubs)/$1" "$stubs/$1"
}

# Moves the stand-in just written to $stubs/$1 into the shared directory, made
# read-only, and links it back. A stand-in another test shared first wins.
share_stub() {
  mkdir -p "$(shared_stubs)"
  chmod 555 "$stubs/$1"
  mv -n "$stubs/$1" "$(shared_stubs)/$1"
  rm -f "$stubs/$1"
  ln -s "$(shared_stubs)/$1" "$stubs/$1"
}

# Gives the test a private, writable copy of a shared stand-in, so it can
# replace the stand-in's contents.
own_stub() {
  local target
  if [[ -L "$stubs/$1" ]]; then
    target=$(readlink "$stubs/$1")
    rm "$stubs/$1"
    cp "$target" "$stubs/$1"
    chmod u+w "$stubs/$1"
  fi
}

stub() {
  link_shared_stub "$1" && return
  cat >"$stubs/$1" <<STUB
#!/usr/bin/env bash
printf '%s %s | state=%s branch=%s\n' "$1" "\$*" "\${TF_VAR_state_directory:-}" "\${TF_VAR_git_branch:-}" >>"\$CALLS"
case "\$*" in
  *" state list"*) printf '%s' "\${TOFU_STATE_LIST:-}" ;;
  *"get ocirepositories.source.toolkit.fluxcd.io cv "*)
    printf '%s\\n' '{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"OCIRepository","metadata":{"name":"cv","namespace":"flux-system","uid":"u"},"spec":{"url":"oci://registry.test/cv","ref":{"digest":"sha256:aaa"},"verify":{"provider":"cosign","matchOIDCIdentity":[{"issuer":"issuer","subject":"subject"}]}},"status":{}}' ;;
  *"get ocirepositories.source.toolkit.fluxcd.io -l"*)
    if [[ -n "\${OCI_SOURCES:-}" ]]; then printf '%s\\n' "\$OCI_SOURCES"; else printf '%s\\n' '{"items":[{"metadata":{"name":"cv"},"spec":{"verify":{}}}]}'; fi ;;
  *"get ciliumclusterwidenetworkpolicies.cilium.io traffic-fixtures-permit"*)
    if [[ -n "\${PERMIT_MISSING:-}" ]]; then exit 1; fi ;;
  *"get namespace cilium-test-1"*)
    if [[ -n "\${CILIUM_TEST_NAMESPACE_MISSING:-}" ]]; then exit 1; fi ;;
  *" get pod holder "*) printf '%s\\n' 10.0.0.12 ;;
  *" exec holder "*) printf '%s\\n' "\${TV_LISTENING:-exit=0}" ;;
  *" apply -f -"*) cat >>"\$BATS_TEST_TMPDIR/applied" ;;
  *" wait "*"ocirepositories"*)
    if [[ -n "\${TV_FAIL:-}" && "\$*" == *"\$TV_FAIL"* ]]; then exit 1; fi ;;
  *" exec "*"hubble observe"*)
    if [[ "\$*" == *"--verdict \${NP_NO_FLOW:-none} "* ]]; then exit 0; fi
    printf '%s\\n' 'Oct 10 10:53:20.425: probe -> target FLOW' ;;
  *"get pods -l k8s-app=hubble-relay"*) printf '%s\\n' '{"items":[{"status":{"podIP":"10.0.0.7","hostIP":"192.168.0.2"}}]}' ;;
  *"-n openbao get pods"*) printf '%s\\n' '{"items":[{"status":{"podIP":"10.0.0.5","hostIP":"192.168.0.2"}}]}' ;;
  *"-n cv get pods"*) printf '%s\\n' '{"items":[{"status":{"podIP":"10.0.0.9","hostIP":"192.168.0.2"}}]}' ;;
  *" get pods "*) cat "\${PODS:-/dev/null}" ;;
  *"get charts.helm.k0sproject.io"*)
    if [[ -n "\${K0S_CHARTS_ERROR:-}" ]]; then printf '%s\\n' "\$K0S_CHARTS_ERROR" >&2; exit 1; fi
    printf '%s' "\${K0S_CHARTS:-}" ;;
  *"hubble port-forward"*) exec nc -l 127.0.0.1 "\${@: -1}" >/dev/null ;;
  *" port-forward "*) local_port="\${*: -1}"; exec nc -l 127.0.0.1 "\${local_port%%:*}" >/dev/null ;;
  *"get nodes -o name"*) printf '%s' "\${NODES:-}" ;;
  *" -n default run "*"nslookup"*) printf '%s\\n' "\${NP_RESOLVED:-exit=0}" ;;
  *" -n cv run "*)
    printf '%s\\n' "\${NP_TENANT_API:-wget: download timed out exit=1}" ;;
  *" -n default run "*"nc -z"*) printf '%s\\n' "\${NP_PROVIDER_DENIED:-exit=1}" ;;
  *" run "*"nc -z"*) printf '%s\\n' "\${NP_ALLOWED:-exit=0}" ;;
  *" -n default run "*)
    printf '%s\\n' "\${NP_DENIED:-wget: can\'t connect to remote host: Operation timed out exit=1}" ;;
  *"get configmap cilium-values-policy "*) printf '%s' "\${CILIUM_VALUES_POLICY:-}" ;;
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
  *"k0s kubectl get --raw /readyz"*)
    if [[ -n "\${READYZ_ERROR:-}" && -z "\${MACHINE_READYZ_OK:-}" ]]; then printf '%s\\n' "\$READYZ_ERROR" >&2; exit 1; fi
    printf 'ok' ;;
  *"get --raw /readyz"*)
    if [[ -n "\${READYZ_ERROR:-}" ]]; then printf '%s\\n' "\$READYZ_ERROR" >&2; exit 1; fi
    printf 'ok' ;;
esac
exit 0
STUB
  chmod +x "$stubs/$1"
  share_stub "$1"
}

# Makes sleep return at once, for a test that waits for something a stand-in
# never provides.
stub_sleep() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/sleep"
  chmod +x "$stubs/sleep"
}

# Builds a stand-in repository holding the real .mise directory and an empty
# file at each given path, and prints its root.
make_repository() {
  local repository="$BATS_TEST_TMPDIR/repository" path
  mkdir -p "$repository"
  ln -sfn "$root_directory/.mise" "$repository/.mise"
  for path in "$@"; do
    mkdir -p "$repository/$(dirname -- "$path")"
    # An environment names the one cluster definition the fixtures use.
    if [[ "$path" == environments/*/environment.yaml ]]; then
      printf 'cluster: singularity\n' >"$repository/$path"
    else
      : >"$repository/$path"
    fi
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
