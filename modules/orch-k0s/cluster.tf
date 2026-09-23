locals {
  k0s_cluster_config = {
    apiVersion = "k0s.k0sproject.io/v1beta1"
    kind       = "ClusterConfig"
    metadata = {
      name = var.cluster_name
    }
    spec = merge(
      {
        api = {
          externalAddress = var.api_address
          port            = var.api_port
        }
        network = {
          provider    = "custom"
          podCIDR     = "10.244.0.0/16"
          serviceCIDR = "10.96.0.0/12"
          kubeProxy = {
            disabled = var.kube_proxy_replacement
          }
        }
      },
      # k0s installs these charts itself and uninstalls any chart removed from this list.
      length(var.helm_charts) > 0 ? { extensions = local.helm_extension } : {},
    )
  }

  helm_extension = {
    helm = {
      repositories = distinct([for helm_chart in var.helm_charts : helm_chart.repository])
      charts       = [for helm_chart in var.helm_charts : helm_chart.chart]
    }
  }
}

resource "k0sctl_config" "this" {
  metadata {
    name = var.cluster_name
  }

  spec {
    k0s {
      version = "1.36.4+k0s.0"
      config  = yamlencode(local.k0s_cluster_config)
    }

    host {
      role      = "controller+worker"
      no_taints = true

      ssh {
        address  = var.ssh_address
        user     = var.ssh_user
        port     = var.ssh_port
        key_path = var.ssh_key_path
      }
    }
  }
}
