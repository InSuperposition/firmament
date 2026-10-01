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
  ssh_key_path = coalesce(var.orbstack_ssh_key_path, pathexpand("~/.orbstack/ssh/id_ed25519"))

  # The machine-hosts contract: everything the Kubernetes root needs to
  # reach this machine, and nothing about OrbStack beyond it.
  machine_hosts = {
    name       = module.vm_orb.name
    dns_name   = module.vm_orb.dns_name
    ip_address = module.vm_orb.ip_address
    ssh = {
      address  = module.vm_orb.root_ssh.address
      port     = module.vm_orb.root_ssh.port
      user     = module.vm_orb.root_ssh.user
      key_path = local.ssh_key_path
    }
  }
}

module "vm_orb" {
  source = "../../modules/vm-orb"
}

module "os_ubuntu" {
  source     = "../../modules/os-ubuntu"
  ssh_target = module.vm_orb.ssh_target
}

# Written only after the readiness postconditions pass, so the Kubernetes
# root never starts on a host that failed them. Destroying this root deletes
# the file, so a missing file means no machine.
resource "local_file" "machine_hosts" {
  filename        = "${var.state_directory}/machine-hosts.yaml"
  content         = yamlencode(local.machine_hosts)
  file_permission = "0644"

  depends_on = [module.os_ubuntu]
}
