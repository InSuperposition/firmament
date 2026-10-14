locals {
  # OrbStack's SSH multiplexer: one address and port for every machine, a
  # client key OrbStack creates, and the server keys it records in its own
  # known_hosts under the bracketed address.
  ssh_proxy_address = "127.0.0.1"
  ssh_proxy_port    = 32222
  ssh_key_path      = pathexpand("~/.orbstack/ssh/id_ed25519")
  known_hosts_path  = pathexpand("~/.orbstack/ssh/known_hosts")
  known_hosts_lines = try(split("\n", file(local.known_hosts_path)), [])

  # Each matching line is "<host> <type> <base64 key>"; the contract holds
  # "<type> <base64 key>".
  ssh_host_keys = [
    for line in local.known_hosts_lines :
    join(" ", slice(split(" ", trimspace(line)), 1, 3))
    if startswith(line, "[${local.ssh_proxy_address}]:${local.ssh_proxy_port} ")
  ]
}

output "id" {
  value       = orbstack_machine.this.id
  description = "The machine name, not OrbStack's internal ULID — this provider does not surface the ULID."
}

output "name" {
  value = orbstack_machine.this.name
}

output "ip_address" {
  value = orbstack_machine.this.ip_address
}

output "status" {
  value = orbstack_machine.this.status
}

output "dns_name" {
  value       = "${orbstack_machine.this.name}.orb.local"
  description = "OrbStack's per-machine DNS name."
}

output "ssh_target" {
  value       = "${orbstack_machine.this.name}@orb"
  description = "The default-user SSH target through OrbStack's built-in SSH alias: the user is the host's own, so nothing is pinned."
}

output "ssh" {
  description = "How a tool that needs root, such as k0sctl, reaches the machine through OrbStack's SSH multiplexer: the address, port, user and client key, and the multiplexer's server keys as known_hosts entries."
  value = {
    address   = local.ssh_proxy_address
    port      = local.ssh_proxy_port
    user      = "root@${orbstack_machine.this.name}"
    key_path  = local.ssh_key_path
    host_keys = local.ssh_host_keys
  }

  precondition {
    condition     = length(local.ssh_host_keys) >= 1
    error_message = "${local.known_hosts_path} has no key for [${local.ssh_proxy_address}]:${local.ssh_proxy_port}; start OrbStack and open an SSH session once so it records its server keys."
  }
}
