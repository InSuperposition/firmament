output "helm_chart" {
  value       = local.helm_chart
  description = "Cilium Helm repository and chart declaration, for a cluster's Helm chart installer."
}
