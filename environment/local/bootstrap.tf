# Installs Flux Operator and the FluxInstance once, then leaves both to Flux.
# The chart digest, the operator values and the FluxInstance are read from
# components/gitops-flux, so Flux and the bootstrap install the same bytes.
locals {
  # Increment only to rerun the bootstrap on purpose, for example after a
  # failed bootstrap, without rebuilding the machine.
  bootstrap_revision = 1

  gitops_flux           = "${path.module}/../../components/gitops-flux"
  flux_operator_source  = yamldecode(file("${local.gitops_flux}/ocirepository.yaml"))
  flux_operator_release = yamldecode(file("${local.gitops_flux}/helmrelease.yaml"))

  # Substituted into the FluxInstance by the bootstrap, and by the root
  # Kustomization from the flux-runtime-info ConfigMap afterwards.
  runtime_info = {
    environment = basename(abspath(path.module))
    git_branch  = var.git_branch
  }
}

module "bootstrap_flux" {
  # v0.8.0
  source = "git::https://github.com/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap.git?ref=d3e18c3c51bec8e77eaf9f1ea66942033bf553cb"

  revision = local.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${local.gitops_flux}/fluxinstance.yaml")
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

  # The Job runs once, with no retry, as soon as the node is Ready, which can
  # be before CoreDNS answers. On the host network it resolves names through
  # the node, and it reaches the API server directly instead of through the
  # kubernetes Service.
  job = {
    host_network = true
    env = {
      KUBERNETES_SERVICE_HOST = local.api_address
      KUBERNETES_SERVICE_PORT = tostring(local.api_port)
    }
  }
}
