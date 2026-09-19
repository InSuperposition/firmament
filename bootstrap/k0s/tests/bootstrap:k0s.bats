#!/usr/bin/env bats
load setup.bash

@test "renders connection values into the native k0sctl contract" {
  run bash "$script" render
  [ "$status" -eq 0 ]
  [ "$output" = "$(rendered_config)" ]
  [ "$(yq -r '.spec.hosts[0].ssh.address' "$(rendered_config)")" = 127.0.0.1 ]
  [ "$(yq -r '.spec.hosts[0].ssh.user' "$(rendered_config)")" = 'developer@firmament' ]
  [ "$(yq -r '.spec.hosts[0].ssh.port' "$(rendered_config)")" = 32222 ]
  [ "$(yq -r '.spec.hosts[0].ssh.keyPath' "$(rendered_config)")" = /tmp/orbstack-test-key ]
  [ "$(yq -r '.spec.k0s.config.spec.api.externalAddress' "$(rendered_config)")" = firmament.orb.local ]
}

@test "preserves the declarative cluster contract" {
  run bash "$script" render
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.hosts[0].role' "$(rendered_config)")" = 'controller+worker' ]
  [ "$(yq -r '.spec.k0s.version' "$(rendered_config)")" = '1.36.4+k0s.0' ]
  [ "$(yq -r '.spec.k0s.config.spec.network.provider' "$(rendered_config)")" = custom ]
  [ "$(yq -r '.spec.k0s.config.spec.network.podCIDR' "$(rendered_config)")" = 10.244.0.0/16 ]
  [ "$(yq -r '.spec.k0s.config.spec.network.serviceCIDR' "$(rendered_config)")" = 10.96.0.0/12 ]
  [ "$(yq -r '.spec.k0s.config.spec.network.kubeProxy.disabled' "$(rendered_config)")" = true ]
}

@test "requires every connection input" {
  unset FIRMAMENT_K0S_SSH_KEY
  run bash "$script" render
  [ "$status" -eq 1 ]
  [[ "$output" == *FIRMAMENT_K0S_SSH_KEY* ]]
}

@test "rejects unsafe connection values" {
  export FIRMAMENT_K0S_SSH_ADDRESS='host with spaces'
  run bash "$script" render
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid SSH address'* ]]
}

@test "does not leave a rendered file after a failed mode" {
  export FIRMAMENT_K0S_API_ADDRESS=''
  run bash "$script" render
  [ "$status" -eq 1 ]
  [ ! -e "$(rendered_config)" ]
}
