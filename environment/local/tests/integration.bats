#!/usr/bin/env bats
load setup.bash

@test "installs no Helm charts through k0s" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec | has("extensions")' <<<"$output")" = false ]
}

@test "replaces kube-proxy with Cilium on the netkit datapath" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$output")" = true ]
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.kube_proxy_replacement' <<<"$output")" = true ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.cilium_datapath_mode' <<<"$output")" = netkit ]
}

@test "points Cilium at the API address and port k0s advertises" {
  run cluster_config
  [ "$status" -eq 0 ]
  api_address=$(yq -r '.spec.api.externalAddress' <<<"$output")
  api_port=$(yq -r '.spec.api.port' <<<"$output")
  [ "$api_address" = firmament.orb.local ]
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.api_address' <<<"$output")" = "$api_address" ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.api_port' <<<"$output")" = "$api_port" ]
  [ "$(yq -r '.managedResources.runtimeInfo.data.cilium_operator_replicas' <<<"$output")" = 1 ]
}

@test "never drains the single node before an upgrade" {
  run k0sctl_config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.no_drain' <<<"$output")" = true ]
}

@test "bootstraps Cilium from the chart digest the cni-cilium component pins" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  chart=$(yq '.gitopsResources.prerequisites.charts[0]' <<<"$output")
  source_url=$(yq -r '.spec.url' "$components_directory/cni-cilium/ocirepository.yaml")
  digest=$(yq -r '.spec.ref.digest' "$components_directory/cni-cilium/ocirepository.yaml")
  [ "$(yq -r '.gitopsResources.prerequisites.charts | length' <<<"$output")" = 1 ]
  [ "$(yq -r '.repository' <<<"$chart")" = "${source_url#oci://}@$digest" ]
  [ "$(yq -r '.version' <<<"$chart")" = "" ]
}

@test "bootstraps Cilium under the release identity Flux adopts" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  chart=$(yq '.gitopsResources.prerequisites.charts[0]' <<<"$output")
  release="$components_directory/cni-cilium/helmrelease.yaml"
  [ "$(yq -r '.name' <<<"$chart")" = "$(yq -r '.spec.releaseName' "$release")" ]
  [ "$(yq -r '.namespace' <<<"$chart")" = "$(yq -r '.spec.storageNamespace' "$release")" ]
  [ "$(yq -r '.createNamespace' <<<"$chart")" = false ]
  [ "$(yq -r '.fluxAdoptionCheck | .resource + " " + .namespace + "/" + .name' <<<"$chart")" = "daemonset.apps kube-system/cilium" ]
}

@test "bootstraps Cilium with the values Flux applies" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  flux_values=$(kubectl kustomize "$environment_directory/flux" | yq -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .data["values.yaml"]')
  [ -n "$flux_values" ]
  [ "$(yq -r '.gitopsResources.prerequisites.charts[0].values' <<<"$output")" = "$flux_values" ]
}

@test "runs the bootstrap Job before the pod network exists" {
  run bootstrap_values
  [ "$status" -eq 0 ]
  [ "$(yq -r '.job.tolerations[] | select(.key == "node.kubernetes.io/not-ready") | .operator' <<<"$output")" = Exists ]
  [ "$(yq -r '.job.tolerations[] | select(.key == "node.cilium.io/agent-not-ready") | .operator' <<<"$output")" = Exists ]
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
