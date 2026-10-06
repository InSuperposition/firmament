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
  # The environment's data names the cluster definition it runs.
  environment_file = "${coalesce(var.environments_directory, "${path.module}/../../environments")}/${var.environment}/environment.yaml"
  environment_data = yamldecode(file(local.environment_file))
  cluster          = local.environment_data.cluster

  machine_name = "${var.environment}-${local.cluster}"

  # The machine-hosts contract: everything the Kubernetes root needs to
  # reach this machine, and nothing about OrbStack beyond it.
  machine_hosts = {
    name       = module.vm_orb.name
    dns_name   = module.vm_orb.dns_name
    ip_address = module.vm_orb.ip_address
    ssh        = module.vm_orb.ssh
  }
}

# The machine is named for a cluster the environment allocates; checked
# here, where the environment data is read.
resource "terraform_data" "environment_cluster" {
  input = local.cluster

  lifecycle {
    precondition {
      condition     = try(contains(keys(local.environment_data.clusters), local.cluster), false)
      error_message = "${local.environment_file}: clusters must hold an allocation for the cluster ${try(local.cluster, "")}."
    }
  }
}

module "vm_orb" {
  source = "../../modules/vm-orb"
  name   = local.machine_name

  depends_on = [terraform_data.environment_cluster]
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
