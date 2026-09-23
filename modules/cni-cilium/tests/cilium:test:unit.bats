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

@test "restarts pods on configuration changes and renews Hubble certificates" {
  run chart_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.rollOutCiliumPods' <<<"$output")" = true ]
  [ "$(yq -r '.envoy.rollOutPods' <<<"$output")" = true ]
  [ "$(yq -r '.operator.rollOutPods' <<<"$output")" = true ]
  [ "$(yq -r '.hubble.relay.rollOutPods' <<<"$output")" = true ]
  [ "$(yq -r '.hubble.ui.rollOutPods' <<<"$output")" = true ]
  [ "$(yq -r '.hubble.tls.auto.method' <<<"$output")" = cronJob ]
}

@test "renders the API endpoint, kube-proxy replacement and operator defaults" {
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

@test "quotes a numeric API host as a string" {
  run chart_values -var='api_host=10.0.0.1'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.k8sServiceHost | tag' <<<"$output")" = '!!str' ]
  [ "$(yq -r '.k8sServiceHost' <<<"$output")" = 10.0.0.1 ]
}

@test "rejects an API port that is not a whole TCP port number" {
  local port
  for port in 0 65536 6443.5; do
    run tofu -chdir="$module_directory" plan -input=false \
      -var='api_host=firmament.orb.local' -var='kube_proxy_replacement=true' -var="api_port=$port"
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid API port'* ]]
  done
}

@test "rejects a fractional operator replica count" {
  run tofu -chdir="$module_directory" plan -input=false \
    -var='api_host=firmament.orb.local' -var='kube_proxy_replacement=true' -var='operator_replicas=1.5'
  [ "$status" -eq 1 ]
  [[ "$output" == *'operator_replicas must be a whole number of at least 1'* ]]
}
