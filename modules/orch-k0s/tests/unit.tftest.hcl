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

run "renders_no_extensions_without_helm_charts" {
  command = plan

  assert {
    condition     = !contains(keys(yamldecode(k0sctl_config.this.spec.k0s.config).spec), "extensions")
    error_message = "Without Helm charts, the cluster config must have no extensions."
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

run "renders_helm_charts_into_the_k0s_helm_extension" {
  command = plan

  variables {
    helm_charts = [
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart = {
          name      = "demo"
          chartname = "example/demo"
          version   = "1.2.3"
          namespace = "kube-system"
          values    = "replicas: 1\n"
        }
      },
    ]
  }

  assert {
    condition     = yamldecode(k0sctl_config.this.spec.k0s.config).spec.extensions.helm.repositories == [{ name = "example", url = "https://charts.example.com" }]
    error_message = "The chart's repository must be declared once."
  }
  assert {
    condition = yamldecode(k0sctl_config.this.spec.k0s.config).spec.extensions.helm.charts == [{
      name         = "demo"
      chartname    = "example/demo"
      version      = "1.2.3"
      namespace    = "kube-system"
      values       = "replicas: 1\n"
      forceUpgrade = true
    }]
    error_message = "The chart must render as declared, with forceUpgrade defaulting to true."
  }
  assert {
    condition     = yamldecode(yamldecode(k0sctl_config.this.spec.k0s.config).spec.extensions.helm.charts[0].values).replicas == 1
    error_message = "The chart values must stay valid YAML."
  }
}

run "shares_one_repository_between_charts_that_come_from_it" {
  command = plan

  variables {
    helm_charts = [
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart      = { name = "first", chartname = "example/first", version = "1.0.0", namespace = "kube-system", values = "" }
      },
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart      = { name = "second", chartname = "example/second", version = "2.0.0", namespace = "default", values = "" }
      },
    ]
  }

  assert {
    condition     = length(yamldecode(k0sctl_config.this.spec.k0s.config).spec.extensions.helm.repositories) == 1
    error_message = "Charts from one repository must share its declaration."
  }
  assert {
    condition     = [for chart in yamldecode(k0sctl_config.this.spec.k0s.config).spec.extensions.helm.charts : [chart.name, chart.namespace]] == [["first", "kube-system"], ["second", "default"]]
    error_message = "Both charts must render, in order, with their own namespaces."
  }
}

run "rejects_one_repository_name_pointing_at_two_urls" {
  command = plan

  variables {
    helm_charts = [
      {
        repository = { name = "example", url = "https://a.example.com" }
        chart      = { name = "first", chartname = "example/first", version = "1.0.0", namespace = "kube-system", values = "" }
      },
      {
        repository = { name = "example", url = "https://b.example.com" }
        chart      = { name = "second", chartname = "example/second", version = "1.0.0", namespace = "kube-system", values = "" }
      },
    ]
  }

  expect_failures = [var.helm_charts]
}

run "rejects_two_helm_charts_with_the_same_name" {
  command = plan

  variables {
    helm_charts = [
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart      = { name = "demo", chartname = "example/demo", version = "1.0.0", namespace = "kube-system", values = "" }
      },
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart      = { name = "demo", chartname = "example/demo", version = "1.0.0", namespace = "default", values = "" }
      },
    ]
  }

  expect_failures = [var.helm_charts]
}

run "rejects_helm_chart_values_that_are_not_valid_yaml" {
  command = plan

  variables {
    helm_charts = [
      {
        repository = { name = "example", url = "https://charts.example.com" }
        chart      = { name = "demo", chartname = "example/demo", version = "1.0.0", namespace = "kube-system", values = "replicas: [1\n" }
      },
    ]
  }

  expect_failures = [var.helm_charts]
}

run "rejects_unsafe_connection_values" {
  command = plan

  variables {
    ssh_address = "host with spaces"
  }

  expect_failures = [var.ssh_address]
}
