variables {
  ssh_address  = "127.0.0.1"
  ssh_user     = "developer@firmament"
  ssh_port     = 32222
  ssh_key_path = "/tmp/orbstack-test-key"
  api_address  = "firmament.orb.local"
}

run "plans_connection_values_from_the_inputs" {
  command = plan

  assert {
    condition = [
      k0sctl_config.this.spec.host[0].ssh[0].address,
      k0sctl_config.this.spec.host[0].ssh[0].user,
      k0sctl_config.this.spec.host[0].ssh[0].port,
      k0sctl_config.this.spec.host[0].ssh[0].key_path,
    ] == ["127.0.0.1", "developer@firmament", 32222, "/tmp/orbstack-test-key"]
    error_message = "k0sctl must reach the host with the SSH inputs."
  }
  assert {
    condition     = yamldecode(k0sctl_config.this.spec.k0s.config).spec.api == { externalAddress = "firmament.orb.local", port = 6443 }
    error_message = "k0s must advertise api_address on port 6443 by default."
  }
}

run "preserves_the_declarative_cluster_contract" {
  command = plan

  assert {
    condition     = k0sctl_config.this.spec.host[0].role == "controller+worker" && k0sctl_config.this.spec.host[0].no_taints
    error_message = "The single host must be an untainted controller+worker."
  }
  assert {
    condition     = k0sctl_config.this.spec.k0s.version == "1.36.4+k0s.0"
    error_message = "k0s must be pinned to 1.36.4+k0s.0."
  }
  assert {
    condition = yamldecode(k0sctl_config.this.spec.k0s.config).spec.network == {
      provider    = "custom"
      podCIDR     = "10.244.0.0/16"
      serviceCIDR = "10.96.0.0/12"
      kubeProxy   = { disabled = true }
    }
    error_message = "The network must use a custom CNI, the fixed CIDRs, and no kube-proxy by default."
  }
}

run "serves_the_api_on_the_configured_port" {
  command = plan

  variables {
    api_port = 16443
  }

  assert {
    condition     = yamldecode(k0sctl_config.this.spec.k0s.config).spec.api.port == 16443
    error_message = "The API port must follow api_port."
  }
}

run "rejects_api_port_zero" {
  command = plan

  variables {
    api_port = 0
  }

  expect_failures = [var.api_port]
}

run "rejects_an_api_port_above_65535" {
  command = plan

  variables {
    api_port = 65536
  }

  expect_failures = [var.api_port]
}

run "rejects_a_fractional_api_port" {
  command = plan

  variables {
    api_port = 6443.5
  }

  expect_failures = [var.api_port]
}

run "installs_no_helm_charts_through_k0s" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(k0sctl_config.this.spec.k0s.config).spec), "extensions")
    error_message = "The cluster config must have no extensions: in-cluster add-ons belong to Flux."
  }
}

run "drains_nodes_before_upgrading_by_default" {
  command = plan

  assert {
    condition     = k0sctl_config.this.no_drain == false
    error_message = "k0sctl must drain nodes before upgrading them unless told otherwise."
  }
}

run "skips_the_drain_when_asked" {
  command = plan

  variables {
    drain_before_upgrade = false
  }

  assert {
    condition     = k0sctl_config.this.no_drain == true
    error_message = "drain_before_upgrade = false must reach k0sctl as no_drain = true."
  }
}

run "runs_kube_proxy_when_the_cni_does_not_replace_it" {
  command = plan

  variables {
    kube_proxy_replacement = false
  }

  assert {
    condition     = yamldecode(k0sctl_config.this.spec.k0s.config).spec.network.kubeProxy.disabled == false
    error_message = "k0s must run kube-proxy when the CNI does not replace it."
  }
}

run "rejects_unsafe_connection_values" {
  command = plan

  variables {
    ssh_address = "host with spaces"
  }

  expect_failures = [var.ssh_address]
}
