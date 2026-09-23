terraform {
  required_version = ">= 1.12.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  backend "local" {}
}

locals {
  # OrbStack's machine DNS name resolves on both the host and the guest.
  api_address = module.vm_orb.dns_name
}

module "vm_orb" {
  source = "../../modules/vm-orb"
}

module "os_ubuntu" {
  source     = "../../modules/os-ubuntu"
  ssh_target = module.vm_orb.ssh_target
}

# Reads no orch_k0s output: orch_k0s consumes this chart, so the reverse edge would be a cycle.
module "cni_cilium" {
  source = "../../modules/cni-cilium"

  api_host               = local.api_address
  kube_proxy_replacement = var.kube_proxy_replacement
  operator_replicas      = 1
}

module "orch_k0s" {
  source = "../../modules/orch-k0s"

  ssh_address  = module.vm_orb.root_ssh.address
  ssh_user     = module.vm_orb.root_ssh.user
  ssh_port     = module.vm_orb.root_ssh.port
  ssh_key_path = var.orbstack_ssh_key_path
  api_address  = local.api_address
  cluster_name = module.vm_orb.name

  kube_proxy_replacement = var.kube_proxy_replacement
  helm_charts            = [module.cni_cilium.helm_chart]

  # os_ubuntu's postconditions must pass before k0s touches the host.
  depends_on = [module.os_ubuntu]
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.orch_k0s.kube_yaml
  filename        = "${var.state_directory}/admin.kubeconfig"
  file_permission = "0600"
}
