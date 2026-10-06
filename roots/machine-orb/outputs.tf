output "machine_name" {
  value = module.vm_orb.name
}

output "machine_ip" {
  value = module.vm_orb.ip_address
}

output "machine_status" {
  value = module.vm_orb.status
}

output "machine_hosts_path" {
  value       = local_file.machine_hosts.filename
  description = "The machine-hosts contract the Kubernetes root reads."
}
