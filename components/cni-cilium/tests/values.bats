#!/usr/bin/env bats

setup() {
  component_directory=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)
  # The runtime values local uses; each test overrides what it checks.
  export api_address=firmament.orb.local api_port=6443 kube_proxy_replacement=true
  export cilium_datapath_mode=netkit cilium_operator_replicas=1
}

# Prints values.yaml the way Flux and the bootstrap apply it: with every
# ${...} variable substituted, failing on any variable left unset.
rendered_values() {
  flux envsubst --strict <"$component_directory/values.yaml"
}

value() {
  rendered_values | yq -r "$1"
}

release() {
  yq -r "$1" "$component_directory/helmrelease.yaml"
}

@test "installs the Cilium chart pinned by digest" {
  [ "$(yq -r '.spec.url' "$component_directory/ocirepository.yaml")" = oci://quay.io/cilium/charts/cilium ]
  [[ "$(yq -r '.spec.ref.digest' "$component_directory/ocirepository.yaml")" =~ ^sha256:[0-9a-f]{64}$ ]]
  [ "$(yq -r '.spec.ref | keys | join(",")' "$component_directory/ocirepository.yaml")" = digest ]
}

@test "adopts the release the bootstrap installed, in kube-system" {
  [ "$(release '.spec.releaseName')" = cilium ]
  [ "$(release '.spec.targetNamespace')" = kube-system ]
  [ "$(release '.spec.storageNamespace')" = kube-system ]
  [ "$(release '.spec.chartRef.name')" = "$(yq -r '.metadata.name' "$component_directory/ocirepository.yaml")" ]
}

@test "upgrades by patching, and rolls back after three failed attempts" {
  [ "$(release '.spec.upgrade.force')" = false ]
  [ "$(release '.spec.rollback.force')" = false ]
  [ "$(release '.spec.upgrade.strategy.name')" = RemediateOnFailure ]
  [ "$(release '.spec.upgrade.remediation.retries')" = 3 ]
  [ "$(release '.spec.upgrade.remediation.strategy')" = rollback ]
  [ "$(release '.spec.upgrade.remediation.remediateLastFailure')" = true ]
}

@test "survives a Git deletion" {
  [ "$(release '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]')" = disabled ]
}

@test "reads its values from the cilium-values ConfigMap and upgrades when they change" {
  run kubectl kustomize "$component_directory"
  [ "$status" -eq 0 ]
  configmap=$(yq 'select(.kind == "ConfigMap")' <<<"$output")
  [ "$(yq -r '.metadata.name' <<<"$configmap")" = cilium-values ]
  [ "$(yq -r '.metadata.namespace' <<<"$configmap")" = flux-system ]
  [ "$(yq -r '.metadata.labels["reconcile.fluxcd.io/watch"]' <<<"$configmap")" = Enabled ]
  [ "$(yq -r '.data["values.yaml"]' <<<"$configmap")" = "$(cat "$component_directory/values.yaml")" ]
  [ "$(release '.spec.valuesFrom[0].kind + "/" + .spec.valuesFrom[0].name + ":" + .spec.valuesFrom[0].valuesKey')" = ConfigMap/cilium-values:values.yaml ]
}

@test "refuses to render while a runtime value is missing" {
  unset cilium_datapath_mode
  run rendered_values
  [ "$status" -ne 0 ]
}

@test "replaces kube-proxy on the netkit datapath with BPF masquerading" {
  [ "$(value '.kubeProxyReplacement')" = true ]
  [ "$(value '.bpf.datapathMode')" = netkit ]
  [ "$(value '.bpf.masquerade')" = true ]
}

@test "falls back to veth and iptables masquerading beside kube-proxy" {
  kube_proxy_replacement=false cilium_datapath_mode=veth
  [ "$(value '.kubeProxyReplacement')" = false ]
  [ "$(value '.bpf.datapathMode')" = veth ]
  [ "$(value '.bpf.masquerade')" = false ]
}

@test "reaches the API server at the runtime address and port" {
  api_port=16443
  [ "$(value '.k8sServiceHost')" = firmament.orb.local ]
  [ "$(value '.k8sServicePort')" = 16443 ]
  [ "$(value '.k8sServicePort | type')" = '!!int' ]
}

@test "keeps a numeric API address a string" {
  api_address=10.0.0.1
  [ "$(value '.k8sServiceHost')" = 10.0.0.1 ]
  [ "$(value '.k8sServiceHost | type')" = '!!str' ]
}

@test "runs the operator replica count the runtime sets" {
  [ "$(value '.operator.replicas')" = 1 ]
  cilium_operator_replicas=2
  [ "$(value '.operator.replicas')" = 2 ]
  [ "$(value '.operator.replicas | type')" = '!!int' ]
}

@test "assigns pod IPs from the Kubernetes podCIDR" {
  [ "$(value '.ipam.mode')" = kubernetes ]
}

@test "limits socket load balancing to the host namespace" {
  [ "$(value '.socketLB.hostNamespaceOnly')" = true ]
}

@test "runs Hubble Relay and UI, with certificates renewed by a CronJob" {
  [ "$(value '.hubble.relay.enabled')" = true ]
  [ "$(value '.hubble.ui.enabled')" = true ]
  [ "$(value '.hubble.tls.auto.method')" = cronJob ]
}

@test "restarts every component's pods when its configuration changes" {
  [ "$(value '[.rollOutCiliumPods, .envoy.rollOutPods, .operator.rollOutPods, .hubble.relay.rollOutPods, .hubble.ui.rollOutPods] | all')" = true ]
}

@test "keeps L7 traffic in a standalone Envoy through agent restarts" {
  [ "$(value '.envoy.enabled')" = true ]
}

@test "keeps the defaults of the version first installed" {
  [ "$(value '.upgradeCompatibility')" = 1.20 ]
  [ "$(value '.upgradeCompatibility | type')" = '!!str' ]
}

@test "pulls every enabled image by digest" {
  [ "$(value '[.image, .envoy.image, .operator.image, .certgen.image, .hubble.relay.image, .hubble.ui.backend.image, .hubble.ui.frontend.image] | map(.useDigest) | all')" = true ]
}
