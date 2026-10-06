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

  # The environment's data names the cluster definition it runs.
  environment_file = "${coalesce(var.environments_directory, "${path.module}/../../environments")}/${var.environment}/environment.yaml"
  environment_data = yamldecode(file(local.environment_file))
  cluster          = local.environment_data.cluster

  environment_required_fields = ["cluster", "target", "engine", "artifact_source", "clusters"]
  environment_fields          = concat(local.environment_required_fields, ["credentials"])

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
    cluster                  = local.cluster
    git_branch               = var.git_branch
  }
}

# The machine-hosts contract, checked where it is read. The same fields
# contracts/machine-hosts/schema.cue declares; contracts:lint checks the
# sample against that schema and this checks the file the machine root wrote.
resource "terraform_data" "machine_hosts_contract" {
  input = local.machine

  lifecycle {
    precondition {
      condition     = try(can(regex("^[a-z][a-z0-9-]*$", local.machine.name)) && local.machine.dns_name != "", false)
      error_message = "machine-hosts.yaml: name must be lowercase letters, digits and -, starting with a letter, and dns_name must be set."
    }
    precondition {
      condition     = try(can(cidrhost("${local.machine.ip_address}/32", 0)) || can(cidrhost("${local.machine.ip_address}/128", 0)), false)
      error_message = "machine-hosts.yaml: ip_address must be an IP address."
    }
    precondition {
      condition     = try(local.machine.ssh.address != "" && local.machine.ssh.user != "" && local.machine.ssh.key_path != "", false)
      error_message = "machine-hosts.yaml: ssh.address, ssh.user and ssh.key_path must be set."
    }
    precondition {
      condition = try(
        jsonencode(local.machine.ssh.port) == tostring(local.machine.ssh.port) &&
        local.machine.ssh.port == floor(local.machine.ssh.port) &&
        local.machine.ssh.port >= 1 && local.machine.ssh.port <= 65535,
        false
      )
      error_message = "machine-hosts.yaml: ssh.port must be an integer from 1 to 65535."
    }
    precondition {
      condition = try(alltrue([
        for key in try(local.machine.ssh.host_keys, []) :
        can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+$", key))
      ]), false)
      error_message = "machine-hosts.yaml: ssh.host_keys must be a list of known_hosts key strings, '<type> <base64 key>'."
    }
  }
}

# The environment contract, checked where it is read: the same top-level
# fields contracts/environment/schema.cue declares. The mesh allocations in
# clusters are checked by the OpenTofu allocation rules, not here.
resource "terraform_data" "environment_contract" {
  input = local.environment_data

  lifecycle {
    precondition {
      condition     = try(can(regex("^[a-z][a-z0-9-]*$", local.environment_data.cluster)), false)
      error_message = "environment.yaml: cluster must be lowercase letters, digits and -, starting with a letter."
    }
    precondition {
      condition     = try(local.environment_data.target == "orbstack" && local.environment_data.engine == "flux", false)
      error_message = "environment.yaml: target must be orbstack and engine must be flux."
    }
    precondition {
      condition     = try(can(regex("^ghcr\\.io/[a-z0-9._/-]+$", local.environment_data.artifact_source)), false)
      error_message = "environment.yaml: artifact_source must be a ghcr.io repository, lowercase."
    }
    precondition {
      condition     = try(contains(keys(local.environment_data.clusters), local.environment_data.cluster), false)
      error_message = "environment.yaml: clusters must hold an allocation for the cluster ${try(local.environment_data.cluster, "")}."
    }
    precondition {
      condition = try(
        length(setsubtract(keys(local.environment_data), local.environment_fields)) == 0 &&
        length(setsubtract(local.environment_required_fields, keys(local.environment_data))) == 0,
        false
      )
      error_message = "environment.yaml: allowed fields are ${join(", ", local.environment_fields)}; ${join(", ", setsubtract(local.environment_required_fields, try(keys(local.environment_data), [])))} missing; found undeclared ${try(join(", ", sort(setsubtract(keys(local.environment_data), local.environment_fields))), "none")}."
    }
  }
}

# Flux syncs clusters/<cluster>/flux, so the cluster the environment names
# must exist; checked here, where the environment data is read.
resource "terraform_data" "cluster_definition" {
  input = local.cluster

  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/../../clusters/${local.cluster}/flux/kustomization.yaml")
      error_message = "${local.environment_file} names cluster '${local.cluster}', but clusters/${local.cluster}/flux/kustomization.yaml does not exist."
    }
  }

  depends_on = [terraform_data.environment_contract]
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
