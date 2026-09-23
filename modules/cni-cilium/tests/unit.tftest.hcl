variables {
  api_host               = "firmament.orb.local"
  kube_proxy_replacement = true
}

run "declares_the_pinned_cilium_chart_from_the_cilium_repository" {
  command = plan

  assert {
    condition     = output.helm_chart.repository == { name = "cilium", url = "https://helm.cilium.io" }
    error_message = "The chart must come from the cilium repository at https://helm.cilium.io."
  }
  assert {
    condition     = output.helm_chart.chart.name == "cilium" && output.helm_chart.chart.chartname == "cilium/cilium"
    error_message = "The chart must be cilium/cilium, named cilium."
  }
  assert {
    condition     = output.helm_chart.chart.version == "1.20.2"
    error_message = "The chart must be pinned to 1.20.2."
  }
  assert {
    condition     = output.helm_chart.chart.namespace == "kube-system"
    error_message = "The chart must install into kube-system."
  }
  assert {
    condition     = output.helm_chart.chart.forceUpgrade == false
    error_message = "Upgrades must patch, not force: the hubble-generate-certs Job cannot be recreated in place."
  }
}

run "renders_the_datapath_ipam_and_hubble_values" {
  command = plan

  assert {
    condition     = yamldecode(output.helm_chart.chart.values).bpf == { datapathMode = "netkit", masquerade = true }
    error_message = "Kube-proxy replacement must select netkit with BPF masquerading."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).ipam.mode == "kubernetes"
    error_message = "Pod IPs must come from the Kubernetes podCIDR."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).hubble.relay.enabled && yamldecode(output.helm_chart.chart.values).hubble.ui.enabled
    error_message = "Hubble Relay and Hubble UI must be enabled."
  }
}

run "restarts_pods_on_configuration_changes_and_renews_hubble_certificates" {
  command = plan

  assert {
    condition = alltrue([
      yamldecode(output.helm_chart.chart.values).rollOutCiliumPods,
      yamldecode(output.helm_chart.chart.values).envoy.rollOutPods,
      yamldecode(output.helm_chart.chart.values).operator.rollOutPods,
      yamldecode(output.helm_chart.chart.values).hubble.relay.rollOutPods,
      yamldecode(output.helm_chart.chart.values).hubble.ui.rollOutPods,
    ])
    error_message = "Every Cilium component must roll its pods when its configuration changes."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).hubble.tls.auto.method == "cronJob"
    error_message = "Hubble certificates must be renewed by a CronJob."
  }
}

run "limits_socket_load_balancing_to_the_host_namespace" {
  command = plan

  assert {
    condition     = yamldecode(output.helm_chart.chart.values).socketLB.hostNamespaceOnly == true
    error_message = "Socket load balancing must stay in the host namespace."
  }
}

run "renders_the_api_endpoint_kube_proxy_replacement_and_operator_defaults" {
  command = plan

  assert {
    condition     = yamldecode(output.helm_chart.chart.values).k8sServiceHost == "firmament.orb.local"
    error_message = "Cilium must reach the API at api_host."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).k8sServicePort == 6443
    error_message = "The API port must default to 6443."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).kubeProxyReplacement == true
    error_message = "kubeProxyReplacement must follow kube_proxy_replacement."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).operator.replicas == 2
    error_message = "The operator must default to 2 replicas."
  }
}

run "falls_back_to_veth_and_iptables_masquerading_without_kube_proxy_replacement" {
  command = plan

  variables {
    api_port               = 16443
    kube_proxy_replacement = false
    operator_replicas      = 1
  }

  assert {
    condition     = yamldecode(output.helm_chart.chart.values).k8sServicePort == 16443
    error_message = "The API port must follow api_port."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).kubeProxyReplacement == false
    error_message = "kubeProxyReplacement must follow kube_proxy_replacement."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).bpf == { datapathMode = "veth", masquerade = false }
    error_message = "Without kube-proxy replacement, Cilium must use veth with iptables masquerading."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).operator.replicas == 1
    error_message = "The operator replica count must follow operator_replicas."
  }
}

run "quotes_a_numeric_api_host_as_a_string" {
  command = plan

  variables {
    api_host = "10.0.0.1"
  }

  assert {
    condition     = strcontains(output.helm_chart.chart.values, "k8sServiceHost: \"10.0.0.1\"\n")
    error_message = "The API host must be rendered as a quoted YAML string."
  }
  assert {
    condition     = yamldecode(output.helm_chart.chart.values).k8sServiceHost == "10.0.0.1"
    error_message = "The API host must decode to the string 10.0.0.1."
  }
}

run "rejects_an_unsafe_api_host" {
  command = plan

  variables {
    api_host = "host with spaces"
  }

  expect_failures = [var.api_host]
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

run "rejects_fewer_than_one_operator_replica" {
  command = plan

  variables {
    operator_replicas = 0
  }

  expect_failures = [var.operator_replicas]
}

run "rejects_a_fractional_operator_replica_count" {
  command = plan

  variables {
    operator_replicas = 1.5
  }

  expect_failures = [var.operator_replicas]
}
