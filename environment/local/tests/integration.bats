#!/usr/bin/env bats
load setup.bash

@test "hands the Cilium chart to the k0s Helm extension" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.extensions.helm.repositories[] | select(.name == "cilium") | .url' <<<"$output")" = https://helm.cilium.io ]
  [ "$(yq -r '.spec.extensions.helm.charts[] | select(.name == "cilium") | .chartname' <<<"$output")" = cilium/cilium ]
  [ "$(yq -r '.spec.extensions.helm.charts[] | select(.name == "cilium") | .namespace' <<<"$output")" = kube-system ]
  [ "$(yq -r '.spec.extensions.helm.charts[] | select(.name == "cilium") | .forceUpgrade' <<<"$output")" = false ]
}

@test "points Cilium at the API address and port k0s advertises" {
  run cluster_config
  [ "$status" -eq 0 ]
  api_address=$(yq -r '.spec.api.externalAddress' <<<"$output")
  [ "$api_address" = firmament.orb.local ]
  [ "$(cilium_values <<<"$output" | yq -r '.k8sServiceHost')" = "$api_address" ]
  [ "$(cilium_values <<<"$output" | yq -r '.k8sServicePort')" = "$(yq -r '.spec.api.port' <<<"$output")" ]
  [ "$(cilium_values <<<"$output" | yq -r '.operator.replicas')" = 1 ]
}

@test "replaces kube-proxy with Cilium by default" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$output")" = true ]
  [ "$(cilium_values <<<"$output" | yq -r '.kubeProxyReplacement')" = true ]
  [ "$(cilium_values <<<"$output" | yq -r '.bpf.datapathMode')" = netkit ]
}

@test "runs kube-proxy alongside veth Cilium when replacement is off" {
  run cluster_config -var='kube_proxy_replacement=false'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$output")" = false ]
  [ "$(cilium_values <<<"$output" | yq -r '.kubeProxyReplacement')" = false ]
  [ "$(cilium_values <<<"$output" | yq -r '.bpf.datapathMode')" = veth ]
}

@test "reaches the machine with OrbStack's own SSH key by default" {
  run ssh_key_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.orbstack/ssh/id_ed25519" ]
}

@test "reaches the machine with the SSH key the caller sets" {
  run ssh_key_path -var='orbstack_ssh_key_path=/keys/id_ed25519'
  [ "$status" -eq 0 ]
  [ "$output" = /keys/id_ed25519 ]
}
