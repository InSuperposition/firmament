output "id" {
  value       = orbstack_machine.firmament.id
  description = "The machine name, not OrbStack's internal ULID — this provider does not surface the ULID."
}

output "ip_address" {
  value = orbstack_machine.firmament.ip_address
}

output "status" {
  value = orbstack_machine.firmament.status
}
