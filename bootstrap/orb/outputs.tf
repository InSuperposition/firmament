output "id" {
  value       = orbstack_machine.firmament.id
  description = "orb's identity for this resource — the machine NAME, not its real internal ULID. See FIRMAMENT_FINDINGS.md in the opentofu-provider-orbstack fork."
}

output "ip_address" {
  value = orbstack_machine.firmament.ip_address
}

output "status" {
  value = orbstack_machine.firmament.status
}
