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

@test "replaces kube-proxy with Cilium on the netkit datapath" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$output")" = true ]
  [ "$(cilium_values <<<"$output" | yq -r '.kubeProxyReplacement')" = true ]
  [ "$(cilium_values <<<"$output" | yq -r '.bpf.datapathMode')" = netkit ]
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

@test "bootstraps the Flux Operator chart digest the gitops-flux component pins" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  source_url=$(yq -r '.spec.url' "$components_directory/gitops-flux/ocirepository.yaml")
  digest=$(yq -r '.spec.ref.digest' "$components_directory/gitops-flux/ocirepository.yaml")
  [[ "$digest" == sha256:* ]]
  [ "$(yq -r '.gitopsResources.operatorChart.repository' <<<"$output")" = "${source_url#oci://}@$digest" ]
  [ "$(yq -r '.gitopsResources.operatorChart.version' <<<"$output")" = "" ]
}

@test "bootstraps Flux Operator with the values its HelmRelease declares" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  expected=$(yq -o=json -I=0 '.spec.values' "$components_directory/gitops-flux/helmrelease.yaml")
  [ "$(yq -r '.gitopsResources.operatorChart.values' <<<"$output" | yq -o=json -I=0 '.')" = "$expected" ]
  [[ "$(yq -r '.spec.values.image.tag' "$components_directory/gitops-flux/helmrelease.yaml")" == *@sha256:* ]]
}

@test "bootstraps the FluxInstance the gitops-flux component declares" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.gitopsResources.instance' <<<"$output")" = "$(cat "$components_directory/gitops-flux/fluxinstance.yaml")" ]
}

@test "tells Flux which branch and environment to follow" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.git_branch' <<<"$output")" = feature/test ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.environment' <<<"$output")" = local ]
}

@test "runs the bootstrap Job on the host network, straight to the API server" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.job.hostNetwork' <<<"$output")" = true ]
  [ "$(yq -r '.job.env.KUBERNETES_SERVICE_HOST' <<<"$output")" = firmament.orb.local ]
  [ "$(yq -r '.job.env.KUBERNETES_SERVICE_PORT' <<<"$output")" = 6443 ]
}
