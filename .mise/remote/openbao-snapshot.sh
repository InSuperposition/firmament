#!/bin/sh
# Runs inside the OpenBao pod, handed to `sh -c` by the openbao:* tasks so
# stdin stays free for snapshot data. One subcommand per call:
#   root     print the root certificate from the public endpoint
#   save     log in as role snapshot, write /tmp/openbao.snap, print its SHA-256
#   read     print /tmp/openbao.snap
#   receive  write stdin to /tmp/openbao-restore.snap
#   restore  print the SHA-256 of /tmp/openbao-restore.snap, then restore it
# The login uses the pod's own service account token: no operator key leaves
# the Mac.
set -eu

BAO_ADDR=http://127.0.0.1:8200
export BAO_ADDR
readonly saved=/tmp/openbao.snap
readonly received=/tmp/openbao-restore.snap

log_in() {
  BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=snapshot \
    jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
  export BAO_TOKEN
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

case "${1:?subcommand}" in
root) wget -qO- "$BAO_ADDR/v1/pki/ca/pem" ;;
save)
  log_in
  rm -f "$saved"
  bao operator raft snapshot save "$saved"
  sha256_of "$saved"
  ;;
read) cat "$saved" ;;
receive) cat >"$received" ;;
restore)
  sha256_of "$received"
  log_in
  bao operator raft snapshot restore -force "$received"
  ;;
*)
  printf 'unknown subcommand %s\n' "$1" >&2
  exit 2
  ;;
esac
