locals {
  k0s_cluster_config = {
    apiVersion = "k0s.k0sproject.io/v1beta1"
    kind       = "ClusterConfig"
    metadata = {
      name = var.cluster_name
    }
    spec = {
      api = {
        externalAddress = var.api_address
        port            = var.api_port
      }
      network = {
        provider    = "custom"
        podCIDR     = var.pod_cidr
        serviceCIDR = var.service_cidr
        kubeProxy = {
          disabled = var.kube_proxy_replacement
        }
      }
    }
  }

  # The k0sctl configuration for one controller+worker host. Host trust is
  # strict and read from one file: k0sctl refuses a server key that file
  # does not hold, and never writes to it.
  k0sctl_cluster = {
    apiVersion = "k0sctl.k0sproject.io/v1beta1"
    kind       = "Cluster"
    metadata = {
      name = var.cluster_name
    }
    spec = {
      hosts = [{
        role     = "controller+worker"
        noTaints = true
        # k0sctl downloads the binary on the Mac, keeps it in its cache for the
        # next rebuild and uploads it over SSH, so a stalled download inside the
        # machine cannot use up the apply's time budget.
        uploadBinary = true
        ssh = {
          address         = var.ssh_address
          user            = var.ssh_user
          port            = var.ssh_port
          keyPath         = var.ssh_key_path
          ignoreSSHConfig = true
          options = {
            UserKnownHostsFile    = var.known_hosts_path
            StrictHostKeyChecking = "yes"
          }
        }
      }]
      k0s = {
        version = var.k0s_version
        config  = local.k0s_cluster_config
      }
    }
  }
}

# Records kube_proxy_replacement when the cluster is created. ignore_changes keeps
# that first value, so a later change is caught by the precondition below.
resource "terraform_data" "kube_proxy_replacement_at_creation" {
  input = var.kube_proxy_replacement

  lifecycle {
    ignore_changes = [input]
  }
}
