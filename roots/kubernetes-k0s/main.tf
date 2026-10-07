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

  # Each cluster's mesh allocation reduced to the values that never change:
  # the retired flag is data about the allocation, not part of the record.
  allocations = {
    for name, allocation in local.environment_data.clusters :
    name => { mesh_id = allocation.mesh_id, pod_cidr = allocation.pod_cidr }
  }
  service_cidr = "10.96.0.0/12"

  environment_required_fields = ["cluster", "target", "engine", "artifact_source", "clusters"]
  environment_fields          = concat(local.environment_required_fields, ["credentials"])

  # The machine's recorded IP: an .orb.local name goes stale after a rebuild,
  # and the IP is what the machine-hosts contract holds.
  api_address = local.machine.ip_address
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
      condition = try(
        length(local.machine.ssh.host_keys) >= 1 &&
        alltrue([
          for key in local.machine.ssh.host_keys :
          can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+$", key))
        ]),
        false
      )
      error_message = "machine-hosts.yaml: ssh.host_keys must be a list of at least one known_hosts key string, '<type> <base64 key>'."
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
      condition     = try(!lookup(local.environment_data.clusters[local.environment_data.cluster], "retired", false), false)
      error_message = "environment.yaml: the cluster ${try(local.environment_data.cluster, "")} is retired, so it cannot run."
    }
    precondition {
      condition     = try(length(distinct([for allocation in values(local.allocations) : allocation.mesh_id])) == length(local.allocations), false)
      error_message = "environment.yaml: every cluster needs its own mesh_id; retired clusters keep theirs."
    }
    precondition {
      condition = try(length(flatten([
        for a, allocation_a in local.allocations : [
          for b, allocation_b in local.allocations : "${a}/${b}"
          if a != b && (cidrcontains(allocation_a.pod_cidr, allocation_b.pod_cidr) || cidrcontains(allocation_b.pod_cidr, allocation_a.pod_cidr))
        ]
      ])) == 0, false)
      error_message = "environment.yaml: pod_cidr ranges must not overlap; retired clusters keep theirs."
    }
    precondition {
      condition = try(length([
        for allocation in values(local.allocations) : allocation.pod_cidr
        if cidrcontains(local.service_cidr, allocation.pod_cidr) || cidrcontains(allocation.pod_cidr, local.service_cidr)
      ]) == 0, false)
      error_message = "environment.yaml: a pod_cidr must stay outside the service CIDR ${local.service_cidr}."
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

# The k0sctl trust file: the machine's server keys, one "[address]:port <type>
# <key>" line each, the form known_hosts holds for a host on a port that is
# not 22. k0sctl trusts this file and no other.
resource "local_file" "known_hosts" {
  filename        = "${var.state_directory}/known_hosts"
  file_permission = "0600"
  content = join("\n", concat(
    [for key in local.machine.ssh.host_keys : "[${local.machine.ssh.address}]:${local.machine.ssh.port} ${key}"],
    [""]
  ))

  depends_on = [terraform_data.machine_hosts_contract]
}

module "orch_k0s" {
  source = "../../modules/orch-k0s"

  ssh_address      = local.machine.ssh.address
  ssh_user         = local.machine.ssh.user
  ssh_port         = local.machine.ssh.port
  ssh_key_path     = local.machine.ssh.key_path
  known_hosts_path = abspath(local_file.known_hosts.filename)
  api_address      = local.api_address
  api_port         = local.api_port
  cluster_name     = local.machine.name
  pod_cidr         = local.allocations[local.cluster].pod_cidr
  service_cidr     = local.service_cidr

  kube_proxy_replacement = local.kube_proxy_replacement

  depends_on = [terraform_data.environment_contract]
}

# The configuration the k0sctl edge applies. The task that runs k0sctl reads
# this file; this root runs nothing.
resource "local_file" "k0sctl" {
  filename        = "${var.state_directory}/k0sctl.yaml"
  file_permission = "0600"
  content         = module.orch_k0s.k0sctl_yaml
}

# The cluster-access contract the bootstrap root and the tasks read. It
# says a cluster exists, so it is written only in the publish pass, after
# the task that runs k0sctl has the API answering; every other pass removes
# it. Destroying this root deletes it too.
resource "local_file" "cluster_access" {
  count = var.publish_cluster_access ? 1 : 0

  filename        = "${var.state_directory}/cluster-access.yaml"
  file_permission = "0644"
  content = yamlencode({
    kubeconfig_path = "${var.state_directory}/admin.kubeconfig"
    runtime_info    = local.runtime_info
  })
}

# Mesh allocations are append-only (C22, C78): the first value this root saw
# for a cluster is its record, and a changed pod_cidr or mesh_id, or an entry
# removed from the data instead of marked retired, fails the plan. The records
# live in state, so an environment with no state is not checked; the destroy
# tasks forget them with `tofu state rm` before destroying the root.
resource "terraform_data" "allocation" {
  for_each = local.allocations

  input = each.value

  lifecycle {
    ignore_changes  = [input]
    prevent_destroy = true

    postcondition {
      condition     = self.output == each.value
      error_message = "environment.yaml: the allocation of cluster ${each.key} is append-only; recorded ${jsonencode(self.output)}, found ${jsonencode(each.value)}. Mark a cluster retired: true instead of removing it."
    }
  }

  depends_on = [terraform_data.environment_contract]
}
