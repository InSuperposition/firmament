# Installs Cilium, then Flux Operator and the FluxInstance, once, and leaves
# all three to Flux. Chart digests, release identities, values and the
# FluxInstance are read from packages/cilium and packages/flux,
# so Flux and the bootstrap install the same bytes.
locals {
  # Increment only to rerun the bootstrap on purpose, for example after a
  # failed bootstrap, without rebuilding the machine.
  bootstrap_revision = 1

  packages              = "${path.module}/../../../packages"
  cilium_source         = yamldecode(file("${local.packages}/cilium/ocirepository.yaml"))
  cilium_release        = yamldecode(file("${local.packages}/cilium/helmrelease.yaml"))
  flux_operator_source  = yamldecode(file("${local.packages}/flux/ocirepository.yaml"))
  flux_operator_release = yamldecode(file("${local.packages}/flux/helmrelease.yaml"))
}

module "bootstrap_flux" {
  # v0.8.0
  source = "git::https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap.git?ref=d3e18c3c51bec8e77eaf9f1ea66942033bf553cb"

  revision = local.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${local.packages}/flux/fluxinstance.yaml")
    prerequisites = {
      # Cilium goes first: nothing else gets a pod network until it runs.
      charts = [{
        name             = local.cilium_release.spec.releaseName
        namespace        = local.cilium_release.spec.targetNamespace
        repository       = "${trimprefix(local.cilium_source.spec.url, "oci://")}@${local.cilium_source.spec.ref.digest}"
        create_namespace = false
        values_yaml      = file("${local.packages}/cilium/values.yaml")
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
      data = local.environment.runtime_info
      # A change, such as a new branch to follow, reaches the root
      # Kustomization at once instead of at its next interval.
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
  }

  # The Job installs the pod network, so it runs before one exists: on the
  # host network, resolving names through the node, reaching the API server
  # directly because nothing serves the kubernetes Service yet, and
  # tolerating the node that is not Ready until Cilium runs.
  job = {
    host_network = true
    env = {
      KUBERNETES_SERVICE_HOST = local.environment.runtime_info.api_address
      KUBERNETES_SERVICE_PORT = local.environment.runtime_info.api_port
    }
    tolerations = [
      { key = "node.kubernetes.io/not-ready", operator = "Exists", effect = "NoSchedule" },
      { key = "node.cilium.io/agent-not-ready", operator = "Exists" },
    ]
  }
}
