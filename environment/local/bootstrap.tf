# Installs Flux Operator and the FluxInstance once, then leaves both to Flux.
# The chart digest, the operator values and the FluxInstance are read from
# components/gitops-flux, so Flux and the bootstrap install the same bytes.
locals {
  # Increment only to rerun the bootstrap on purpose, for example after a
  # failed bootstrap, without rebuilding the machine.
  bootstrap_revision = 1

  components            = "${path.module}/../../components"
  cilium_source         = yamldecode(file("${local.components}/cni-cilium/ocirepository.yaml"))
  cilium_release        = yamldecode(file("${local.components}/cni-cilium/helmrelease.yaml"))
  flux_operator_source  = yamldecode(file("${local.components}/gitops-flux/ocirepository.yaml"))
  flux_operator_release = yamldecode(file("${local.components}/gitops-flux/helmrelease.yaml"))

  # Substituted into the manifests and chart values by the bootstrap, and by
  # the root Kustomization from the flux-runtime-info ConfigMap afterwards.
  # Flux substitution is plain text replacement, so every derived value is
  # computed here.
  runtime_info = {
    api_address              = local.api_address
    api_port                 = tostring(local.api_port)
    kube_proxy_replacement   = tostring(local.kube_proxy_replacement)
    cilium_datapath_mode     = local.kube_proxy_replacement ? "netkit" : "veth"
    cilium_operator_replicas = "1"
    environment              = basename(abspath(path.module))
    git_branch               = var.git_branch
  }
}

module "bootstrap_flux" {
  # v0.8.0
  source = "git::https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap.git?ref=d3e18c3c51bec8e77eaf9f1ea66942033bf553cb"

  revision = local.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${local.components}/gitops-flux/fluxinstance.yaml")
    prerequisites = {
      # Cilium goes first: nothing else gets a pod network until it runs.
      charts = [{
        name             = local.cilium_release.spec.releaseName
        namespace        = local.cilium_release.spec.targetNamespace
        repository       = "${trimprefix(local.cilium_source.spec.url, "oci://")}@${local.cilium_source.spec.ref.digest}"
        create_namespace = false
        values_yaml      = file("${local.components}/cni-cilium/values.yaml")
        # Once helm-controller labels the agent DaemonSet, the bootstrap
        # leaves the release to Flux.
        flux_adoption_check = {
          resource  = "daemonset.apps"
          name      = "cilium"
          namespace = local.cilium_release.spec.targetNamespace
        }
      }]
    }
    operator_chart = {
      repository  = "${trimprefix(local.flux_operator_source.spec.url, "oci://")}@${local.flux_operator_source.spec.ref.digest}"
      values_yaml = yamlencode(local.flux_operator_release.spec.values)
    }
  }

  managed_resources = {
    runtime_info = {
      data = local.runtime_info
    }
  }

  # The Job installs the pod network, so it runs before one exists: on the
  # host network, resolving names through the node, reaching the API server
  # directly because nothing serves the kubernetes Service yet, and
  # tolerating the node that is not Ready until Cilium runs.
  job = {
    host_network = true
    env = {
      KUBERNETES_SERVICE_HOST = local.api_address
      KUBERNETES_SERVICE_PORT = tostring(local.api_port)
    }
    tolerations = [
      { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoSchedule" },
      { key = "node.cilium.io/agent-not-ready", operator = "Exists" },
    ]
  }
}
