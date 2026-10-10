#!/usr/bin/env bash
#MISE description="Check the vendored Gateway API definitions against their record: the file must match the SHA-256 in packages/gateway-api/README.md, and so must the upstream release it names (downloads the release, changes nothing)"
set -euo pipefail
# shellcheck source=../../lib.sh
source "${MISE_PROJECT_ROOT:?}/.mise/lib.sh"

readme="$MISE_PROJECT_ROOT/packages/gateway-api/README.md"
vendored="$MISE_PROJECT_ROOT/packages/gateway-api/crds.yaml"

url=$(sed -n 's/^- Version: .*, \(https:\/\/[^ ]*\)$/\1/p' "$readme")
# shellcheck disable=SC2016 # a sed expression with literal backticks, not shell
recorded=$(sed -n 's/^- SHA-256 of `crds.yaml`: `\([0-9a-f]\{64\}\)`$/\1/p' "$readme")
[[ -n "$url" ]] || fail "$readme records no release URL" || exit
[[ -n "$recorded" ]] || fail "$readme records no SHA-256 of crds.yaml" || exit

checksum() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

actual=$(checksum "$vendored")
if [[ "$actual" != "$recorded" ]]; then
  fail "packages/gateway-api/crds.yaml has SHA-256 $actual, the README records $recorded; the file is edited or the record is stale" || exit
fi

download=$(mktemp)
trap 'rm -f "$download"' EXIT
curl -fsSL "$url" -o "$download" || fail "cannot download $url" || exit
upstream=$(checksum "$download")
if [[ "$upstream" != "$recorded" ]]; then
  fail "$url has SHA-256 $upstream, the README records $recorded; the release changed or the record is wrong" || exit
fi
printf 'ok: crds.yaml and %s match the recorded SHA-256 %s\n' "$url" "$recorded"
