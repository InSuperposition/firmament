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
  api_port    = 6443

  # Cilium replaces kube-proxy, on the netkit datapath. k0s and the Cilium
  # values must agree, and orch_k0s fixes the value when the cluster is
  # created.
  kube_proxy_replacement = true

  orbstack_ssh_key_path = coalesce(var.orbstack_ssh_key_path, pathexpand("~/.orbstack/ssh/id_ed25519"))

  # The environment facts every component reads: the bootstrap root puts
  # them in the flux-runtime-info ConfigMap, and the root Kustomization
  # substitutes them. Flux substitution is plain text replacement, so every
  # derived value is computed here.
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
  ssh_key_path = local.orbstack_ssh_key_path
  api_address  = local.api_address
  api_port     = local.api_port
  cluster_name = module.vm_orb.name

  kube_proxy_replacement = local.kube_proxy_replacement
  # One node: a drain would evict every pod with nowhere to go.
  drain_before_upgrade = false

  # os_ubuntu's postconditions must pass before k0s touches the host.
  depends_on = [module.os_ubuntu]
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.orch_k0s.kube_yaml
  filename        = "${var.state_directory}/admin.kubeconfig"
  file_permission = "0600"
}
