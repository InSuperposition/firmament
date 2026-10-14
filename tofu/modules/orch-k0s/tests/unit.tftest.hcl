variables {
  ssh_address      = "127.0.0.1"
  ssh_user         = "root@demo"
  ssh_port         = 32222
  ssh_key_path     = "/keys/id_ed25519"
  known_hosts_path = "/state/known_hosts"
  api_address      = "192.168.139.10"
  pod_cidr         = "10.240.0.0/16"
}

run "renders_the_connection_from_the_inputs" {
  command = plan

  assert {
    condition = [
      yamldecode(output.k0sctl_yaml).spec.hosts[0].ssh.address,
      yamldecode(output.k0sctl_yaml).spec.hosts[0].ssh.user,
      yamldecode(output.k0sctl_yaml).spec.hosts[0].ssh.port,
      yamldecode(output.k0sctl_yaml).spec.hosts[0].ssh.keyPath,
    ] == ["127.0.0.1", "root@demo", 32222, "/keys/id_ed25519"]
    error_message = "k0sctl must reach the host with the SSH inputs."
  }
}

run "trusts_only_the_given_known_hosts_file_and_refuses_unknown_keys" {
  command = plan

  assert {
    condition = yamldecode(output.k0sctl_yaml).spec.hosts[0].ssh == {
      address         = "127.0.0.1"
      user            = "root@demo"
      port            = 32222
      keyPath         = "/keys/id_ed25519"
      ignoreSSHConfig = true
      options = {
        UserKnownHostsFile    = "/state/known_hosts"
        StrictHostKeyChecking = "yes"
      }
    }
    error_message = "Host trust must be strict, read from the given file, and ignore the user's SSH config."
  }
}

run "advertises_the_api_address_on_port_6443_by_default" {
  command = plan

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.config.spec.api == { externalAddress = "192.168.139.10", port = 6443 }
    error_message = "k0s must advertise api_address on port 6443 by default."
  }
}

run "preserves_the_declarative_cluster_contract" {
  command = plan

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.hosts[0].role == "controller+worker" && yamldecode(output.k0sctl_yaml).spec.hosts[0].noTaints
    error_message = "The single host must be an untainted controller+worker."
  }
  assert {
    condition = yamldecode(output.k0sctl_yaml).spec.k0s.config.spec.network == {
      provider    = "custom"
      podCIDR     = "10.240.0.0/16"
      serviceCIDR = "10.96.0.0/12"
      kubeProxy   = { disabled = true }
    }
    error_message = "The network must use a custom CNI, the given pod CIDR, and no kube-proxy by default."
  }
}

run "pins_k0s_to_the_version_variable" {
  command = plan

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.version == var.k0s_version && var.k0s_version == "1.36.4+k0s.1"
    error_message = "k0s must be pinned to the one version the module sets."
  }
}

run "uploads_the_k0s_binary_from_the_host" {
  command = plan

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.hosts[0].uploadBinary == true
    error_message = "k0sctl must download k0s on the host running it and upload it, not download it inside the machine."
  }
}

run "takes_another_k0s_version" {
  command = plan

  variables {
    k0s_version = "1.36.5+k0s.0"
  }

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.version == "1.36.5+k0s.0"
    error_message = "The version must follow k0s_version."
  }
}

run "rejects_a_k0s_version_without_the_k0s_revision" {
  command = plan

  variables {
    k0s_version = "v1.36.4"
  }

  expect_failures = [var.k0s_version]
}

run "serves_the_api_on_the_configured_port" {
  command = plan

  variables {
    api_port = 16443
  }

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.config.spec.api.port == 16443
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
    condition     = !contains(keys(yamldecode(output.k0sctl_yaml).spec.k0s.config.spec), "extensions")
    error_message = "The cluster config must have no extensions: in-cluster add-ons belong to Flux."
  }
}

run "runs_kube_proxy_when_the_cni_does_not_replace_it" {
  command = plan

  variables {
    kube_proxy_replacement = false
  }

  assert {
    condition     = yamldecode(output.k0sctl_yaml).spec.k0s.config.spec.network.kubeProxy.disabled == false
    error_message = "k0s must run kube-proxy when the CNI does not replace it."
  }
}

run "rejects_a_pod_cidr_that_is_not_a_cidr" {
  command = plan

  variables {
    pod_cidr = "10.240.0.0"
  }

  expect_failures = [var.pod_cidr]
}

run "rejects_a_relative_known_hosts_path" {
  command = plan

  variables {
    known_hosts_path = "known_hosts"
  }

  expect_failures = [var.known_hosts_path]
}

run "rejects_unsafe_connection_values" {
  command = plan

  variables {
    ssh_address = "host with spaces"
  }

  expect_failures = [var.ssh_address]
}
