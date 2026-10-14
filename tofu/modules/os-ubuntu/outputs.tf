output "ready" {
  value       = data.external.readiness.result.id
  description = "Non-empty once the readiness preconditions have passed — reference this from a dependent module to force evaluation order."
}
