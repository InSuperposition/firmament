#!/usr/bin/env bats
load setup.bash

@test "declares the pinned Cilium chart from the Cilium repository" {
  run helm_chart
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repository.name' <<<"$output")" = cilium ]
  [ "$(jq -r '.repository.url' <<<"$output")" = https://helm.cilium.io ]
  [ "$(jq -r '.chart.name' <<<"$output")" = cilium ]
  [ "$(jq -r '.chart.chartname' <<<"$output")" = cilium/cilium ]
  [ "$(jq -r '.chart.version' <<<"$output")" = 1.20.2 ]
  [ "$(jq -r '.chart.namespace' <<<"$output")" = kube-system ]
}

@test "renders the datapath, IPAM and Hubble values" {
  run chart_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.bpf.datapathMode' <<<"$output")" = netkit ]
  [ "$(yq -r '.bpf.masquerade' <<<"$output")" = true ]
  [ "$(yq -r '.ipam.mode' <<<"$output")" = kubernetes ]
  [ "$(yq -r '.hubble.relay.enabled' <<<"$output")" = true ]
  [ "$(yq -r '.hubble.ui.enabled' <<<"$output")" = true ]
}

@test "points the agent at the API server with the default port" {
  run chart_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.k8sServiceHost' <<<"$output")" = firmament.orb.local ]
  [ "$(yq -r '.k8sServicePort' <<<"$output")" = 6443 ]
  [ "$(yq -r '.kubeProxyReplacement' <<<"$output")" = true ]
  [ "$(yq -r '.operator.replicas' <<<"$output")" = 2 ]
}

@test "falls back to veth and iptables masquerading without kube-proxy replacement" {
  run chart_values -var='api_port=16443' -var='kube_proxy_replacement=false' -var='operator_replicas=1'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.k8sServicePort' <<<"$output")" = 16443 ]
  [ "$(yq -r '.kubeProxyReplacement' <<<"$output")" = false ]
  [ "$(yq -r '.bpf.datapathMode' <<<"$output")" = veth ]
  [ "$(yq -r '.bpf.masquerade' <<<"$output")" = false ]
  [ "$(yq -r '.operator.replicas' <<<"$output")" = 1 ]
}

@test "requires the kube-proxy mode" {
  run tofu -chdir="$module_directory" plan -input=false -var='api_host=firmament.orb.local'
  [ "$status" -eq 1 ]
  [[ "$output" == *kube_proxy_replacement* ]]
}

@test "rejects an unsafe API host" {
  run tofu -chdir="$module_directory" plan -input=false \
    -var='api_host=host with spaces' -var='kube_proxy_replacement=true'
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid API host'* ]]
}

@test "rejects fewer than one operator replica" {
  run tofu -chdir="$module_directory" plan -input=false \
    -var='api_host=firmament.orb.local' -var='kube_proxy_replacement=true' -var='operator_replicas=0'
  [ "$status" -eq 1 ]
  [[ "$output" == *'operator_replicas must be a whole number of at least 1'* ]]
}
