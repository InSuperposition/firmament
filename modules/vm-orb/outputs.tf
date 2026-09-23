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
  value       = "${var.username}@${orbstack_machine.this.name}@orb"
  description = "The ordinary-user SSH target through OrbStack's built-in SSH alias."
}

output "root_ssh" {
  description = "Connection details for the root@<name> form via OrbStack's SSH multiplexer, used by tools (like k0sctl) that need root and can't use the ordinary-user @orb alias."
  value = {
    address = "127.0.0.1"
    user    = "root@${orbstack_machine.this.name}"
    port    = 32222
  }
}
