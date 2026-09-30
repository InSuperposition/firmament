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
  # The machine the orb:apply task created, from its machine-hosts file. The
  # root installs k0s on one machine.
  machine_hosts_file = coalesce(var.machine_hosts_file, "${var.state_directory}/machine-hosts.yaml")
  machine            = yamldecode(file(local.machine_hosts_file)).hosts[0]

  # OrbStack's machine DNS name resolves on both the host and the guest.
  api_address = "${local.machine.name}.orb.local"
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

module "orch_k0s" {
  source = "../../modules/orch-k0s"

  ssh_address  = local.machine.ssh.address
  ssh_user     = local.machine.ssh.user
  ssh_port     = local.machine.ssh.port
  ssh_key_path = local.orbstack_ssh_key_path
  api_address  = local.api_address
  api_port     = local.api_port
  cluster_name = local.machine.name

  kube_proxy_replacement = local.kube_proxy_replacement
  # One node: a drain would evict every pod with nowhere to go.
  drain_before_upgrade = false
  # Every destroy deletes the machine, which removes k0s with it. A reset
  # over SSH first would be redundant, and fails when the machine is stopped.
  reset_on_destroy = false
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.orch_k0s.kube_yaml
  filename        = "${var.state_directory}/admin.kubeconfig"
  file_permission = "0600"
}
