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

module "vm_orb" {
  source = "../../modules/vm-orb"
}

module "os_ubuntu" {
  source     = "../../modules/os-ubuntu"
  ssh_target = module.vm_orb.ssh_target
}

module "orch_k0s" {
  source = "../../modules/orch-k0s"

  ssh_address  = module.vm_orb.root_ssh.address
  ssh_user     = module.vm_orb.root_ssh.user
  ssh_port     = module.vm_orb.root_ssh.port
  ssh_key_path = var.orbstack_ssh_key_path
  api_address  = module.vm_orb.dns_name
  cluster_name = module.vm_orb.name

  # os_ubuntu's postconditions must pass before k0s touches the host.
  depends_on = [module.os_ubuntu]
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.orch_k0s.kube_yaml
  filename        = "${var.state_directory}/admin.kubeconfig"
  file_permission = "0600"
}
