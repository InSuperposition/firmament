variables {
  ssh_address      = "127.0.0.1"
  ssh_user         = "root@demo"
  ssh_port         = 32222
  ssh_key_path     = "/keys/id_ed25519"
  known_hosts_path = "/state/known_hosts"
  api_address      = "192.168.139.10"
  pod_cidr         = "10.240.0.0/16"
}

# Creates only the record of the creation-time mode; nothing else is
# applied, so no host is contacted.
run "records_kube_proxy_replacement_at_creation" {
  command = apply

  assert {
    condition     = terraform_data.kube_proxy_replacement_at_creation.output == true
    error_message = "The creation-time kube-proxy mode must be recorded."
  }
}

run "renders_again_with_the_creation_time_kube_proxy_mode" {
  command = plan

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.config.spec.network.kubeProxy.disabled == true
    error_message = "An unchanged kube-proxy mode must render."
  }
}

run "rejects_changing_kube_proxy_replacement_after_cluster_creation" {
  command = plan

  variables {
    kube_proxy_replacement = false
  }

  expect_failures = [output.k0sctl_yaml]
}
