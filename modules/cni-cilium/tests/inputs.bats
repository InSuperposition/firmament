#!/usr/bin/env bats
load setup.bash

@test "requires the kube-proxy mode" {
  run tofu -chdir="$module_directory" plan -input=false -var='api_host=firmament.orb.local'
  [ "$status" -eq 1 ]
  [[ "$output" == *kube_proxy_replacement* ]]
}
