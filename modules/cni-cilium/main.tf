terraform {
  required_version = ">= 1.12.0"
}

locals {
  helm_chart = {
    repository = {
      name = "cilium"
      url  = "https://helm.cilium.io"
    }
    chart = {
      name      = "cilium"
      chartname = "cilium/cilium"
      version   = "1.20.2"
      namespace = "kube-system"
      values = templatefile("${path.module}/values.yaml.tftpl", {
        api_host               = var.api_host
        api_port               = var.api_port
        kube_proxy_replacement = var.kube_proxy_replacement
        operator_replicas      = var.operator_replicas
      })
    }
  }
}
