# shellcheck shell=bash
# Helpers for the verify tasks that run one guarantee on request (--only) and
# print what they observed as one JSON object on the last line of their output,
# the shape of an action in contracts/run-record. Source after lib.sh.
#
#   record_begin guarantee command [reference-json]
#   record_step "name of the control being checked"
#   record_pass                      the control in progress passed
#   record_line kind text            keep text around a refusal phrase
#   record_flow verdict count window_seconds
#   record_http status
#   record_merge observations-json   append observations another task printed
#   record_end                       print the object; run it from an EXIT trap
#
# When the task fails, record_end prints the controls that passed, the control
# in progress as failed and the exit status, so the caller can keep the failed
# action in an incomplete record.

readonly record_marker='[line withheld: names an address or a pod]'
readonly record_phrase='(must be signed by the signer|PodSecurity|ephemeral containers are not allowed|no matching CertificateIdentity|no signatures found)'

# Prints the message in $1 that carries a known refusal phrase, from the
# start of the message (after the last "label: " before it, so a policy or
# webhook name is not kept) to the next comma, colon or semicolon. It is kept
# when it is at most 120 characters, $1 holds no dotted IPv4 address and no
# IPv6 group, and the message has no name of three or more dash-separated
# parts. Otherwise the withheld marker is printed. The rule is the one in
# contracts/run-record/schema.cue.
redact_line() {
  local line="$1" clause=""
  if [[ "$line" =~ ^.*:\ ([^:]*${record_phrase}[^,:\;]*) ]]; then
    clause="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ([^:]*${record_phrase}[^,:\;]*) ]]; then
    clause="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$clause" ]] && ((${#clause} <= 120)) &&
    ! [[ "$line" =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] &&
    ! [[ "$line" =~ [0-9A-Fa-f]*:[0-9A-Fa-f]*:[0-9A-Fa-f]* ]] &&
    ! [[ "$clause" =~ [a-z0-9]+(-[a-z0-9]+){2,} ]]; then
    printf '%s' "$clause"
  else
    printf '%s' "$record_marker"
  fi
}

record_begin() {
  record_guarantee="$1"
  record_command="$2"
  record_reference="${3:-null}"
  record_controls='[]'
  record_observations='[]'
  record_step_name="the guarantee ran"
}

record_step() {
  record_step_name="$1"
}

record_pass() {
  record_controls=$(jq -c --arg name "$record_step_name" '. + [{name: $name, passed: true}]' <<<"$record_controls")
}

record_line() {
  local kind="$1" line
  line=$(redact_line "$2")
  record_observations=$(jq -c --arg kind "$kind" --arg line "$line" '. + [{kind: $kind, line: $line}]' <<<"$record_observations")
}

record_flow() {
  record_observations=$(jq -c --arg verdict "$1" --argjson count "$2" --argjson window "$3" \
    '. + [{kind: "flow", verdict: $verdict, count: $count, window_seconds: $window}]' <<<"$record_observations")
}

record_http() {
  record_observations=$(jq -c --argjson status "$1" '. + [{kind: "http", status: $status}]' <<<"$record_observations")
}

record_merge() {
  record_observations=$(jq -c --argjson more "$1" '. + $more' <<<"$record_observations")
}

# Prints the object. $1 is the exit status the task is ending with.
record_end() {
  local status="${1:-0}" controls="$record_controls" observations="$record_observations"
  if ((status != 0)); then
    controls=$(jq -c --arg name "$record_step_name" '. + [{name: $name, passed: false}]' <<<"$controls")
  fi
  if [[ "$observations" == '[]' ]]; then
    observations=$(jq -nc --arg line "$record_marker" '[{kind: "condition", line: $line}]')
  fi
  jq -nc --arg guarantee "$record_guarantee" --arg command "$record_command" --argjson status "$status" \
    --argjson reference "$record_reference" --argjson controls "$controls" --argjson observations "$observations" \
    '{guarantee: $guarantee, command: $command, exit_status: $status, controls: $controls, observations: $observations}
     + (if $reference == null then {} else {reference: $reference} end)'
}
