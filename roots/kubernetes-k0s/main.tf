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
  # The machine-hosts contract the machine root wrote.
  machine = yamldecode(file("${var.state_directory}/machine-hosts.yaml"))

  # The machine's DNS name resolves on both the host and the guest.
  api_address = local.machine.dns_name
  api_port    = 6443

  # Cilium replaces kube-proxy, on the netkit datapath. k0s and the Cilium
  # values must agree, and orch_k0s fixes the value when the cluster is
  # created.
  kube_proxy_replacement = true

  # The environment facts every package reads: the bootstrap root puts
  # them in the flux-runtime-info ConfigMap, and the root Kustomization
  # substitutes them. Flux substitution is plain text replacement, so every
  # derived value is computed here.
  runtime_info = {
    api_address              = local.api_address
    api_port                 = tostring(local.api_port)
    kube_proxy_replacement   = tostring(local.kube_proxy_replacement)
    cilium_datapath_mode     = local.kube_proxy_replacement ? "netkit" : "veth"
    cilium_operator_replicas = "1"
    environment              = var.environment
    git_branch               = var.git_branch
  }
}

module "orch_k0s" {
  source = "../../modules/orch-k0s"

  ssh_address  = local.machine.ssh.address
  ssh_user     = local.machine.ssh.user
  ssh_port     = local.machine.ssh.port
  ssh_key_path = local.machine.ssh.key_path
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

# The cluster-access contract the bootstrap root and the tasks read.
# Destroying this root deletes the file, so a missing file means no cluster.
resource "local_file" "cluster_access" {
  filename        = "${var.state_directory}/cluster-access.yaml"
  file_permission = "0644"
  content = yamlencode({
    kubeconfig_path = local_sensitive_file.kubeconfig.filename
    runtime_info    = local.runtime_info
  })
}
