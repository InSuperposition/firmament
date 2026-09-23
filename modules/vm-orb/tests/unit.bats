#!/usr/bin/env bats
load setup.bash

@test "declares the target machine contract" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = firmament ]
  [ "$(jq -r '.image' <<<"$output")" = ubuntu:resolute ]
  [ "$(jq -r '.arch' <<<"$output")" = arm64 ]
  [ "$(jq -r '.username' <<<"$output")" = tensor ]
}

@test "plan is offline — no live OrbStack calls" {
  local orb_dir
  orb_dir=$(dirname -- "$(command -v orb)")
  local filtered_path=""
  local segment
  IFS=':' read -ra segments <<<"$PATH"
  for segment in "${segments[@]}"; do
    [ "$segment" = "$orb_dir" ] && continue
    filtered_path="${filtered_path:+$filtered_path:}$segment"
  done
  PATH="$filtered_path" run resource_after
  [ "$status" -eq 0 ]
}
