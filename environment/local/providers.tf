# The helm and kubernetes providers reach the cluster orch_k0s creates. On a
# fresh environment the kubeconfig is unknown at plan time, so both providers
# are configured from values that only become known during apply.
locals {
  kubeconfig = yamldecode(module.orch_k0s.kube_yaml)

  kube_cluster = local.kubeconfig.clusters[0].cluster
  kube_user    = local.kubeconfig.users[0].user

  kube_connection = {
    host                   = local.kube_cluster.server
    cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kube_user["client-certificate-data"])
    client_key             = base64decode(local.kube_user["client-key-data"])
  }
}

provider "kubernetes" {
  host                   = local.kube_connection.host
  cluster_ca_certificate = local.kube_connection.cluster_ca_certificate
  client_certificate     = local.kube_connection.client_certificate
  client_key             = local.kube_connection.client_key
}

provider "helm" {
  kubernetes = local.kube_connection
}
