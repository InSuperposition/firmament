variables {
  ssh_address  = "127.0.0.1"
  ssh_user     = "developer@firmament"
  ssh_port     = 32222
  ssh_key_path = "/tmp/orbstack-test-key"
  api_address  = "firmament.orb.local"
}

# Creates only the record of the creation-time mode; the cluster itself is
# not applied, so no SSH connection is made.
run "records_kube_proxy_replacement_at_creation" {
  command = apply

  override_resource {
    target = k0sctl_config.this
  }

  assert {
    condition     = terraform_data.kube_proxy_replacement_at_creation.output == true
    error_message = "The creation-time kube-proxy mode must be recorded."
  }
}

run "plans_again_with_the_creation_time_kube_proxy_mode" {
  command = plan

  assert {
    condition     = yamldecode(k0sctl_config.this.spec.k0s.config).spec.network.kubeProxy.disabled == true
    error_message = "An unchanged kube-proxy mode must plan."
  }
}

run "rejects_changing_kube_proxy_replacement_after_cluster_creation" {
  command = plan

  variables {
    kube_proxy_replacement = false
  }

  expect_failures = [k0sctl_config.this]
}
