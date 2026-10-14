package templates

// One CiliumNetworkPolicy per covered namespace. A rule section on ingress
// (and, in full mode, egress) makes Cilium deny everything else, so the default-deny
// and every allow take effect in one object. A section with no allow is
// written as one empty rule, which denies all.
#Policy: {
	_config: {
		name:   string
		policy: #NamespacePolicy
	}

	_podNamespace: "k8s:io.kubernetes.pod.namespace"

	apiVersion: "cilium.io/v2"
	kind:       "CiliumNetworkPolicy"
	metadata: {
		name:      "platform"
		namespace: _config.name
		// Removing a binding never removes the policy of a namespace that
		// is still there.
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		endpointSelector: {}

		_ingress: [
			// A capability this namespace provides: its consumers' namespaces,
			// on the pod port.
			for prov in _config.policy.provides if len(prov.consumers) > 0 {
				fromEndpoints: [for c in prov.consumers {matchLabels: (_podNamespace): c}]
				toPorts: [{ports: [{port: "\(prov.port)", protocol: prov.protocol}]}]
			},
			// The node's probes, and the API server's webhooks, which k0s
			// tunnels to the pods through the konnectivity agent in kube-system
			// (observed with Hubble: the agent, not the host, is the caller).
			// Cilium refuses fromEndpoints and fromEntities in one rule.
			if len(_config.policy.hostPorts) > 0 {
				fromEntities: ["host"]
				toPorts: [{ports: [for hp in _config.policy.hostPorts {port: "\(hp.port)", protocol: hp.protocol}]}]
			},
			// Pod ports any pod may reach, such as DNS.
			if len(_config.policy.clusterPorts) > 0 {
				fromEntities: ["cluster"]
				toPorts: [{ports: [for cp in _config.policy.clusterPorts {port: "\(cp.port)", protocol: cp.protocol}]}]
			},
			// Pod ports the Gateway's Envoy reaches, which Cilium runs as the
			// reserved ingress endpoint.
			if len(_config.policy.ingressPorts) > 0 {
				fromEntities: ["ingress"]
				toPorts: [{ports: [for ip in _config.policy.ingressPorts {port: "\(ip.port)", protocol: ip.protocol}]}]
			},
			// The pods of an ingress-only namespace talk to each other: the
			// konnectivity agent carries the API server's calls to the
			// metrics server, for one.
			if _config.policy.mode == "ingress" {
				fromEndpoints: [{}]
			},
			if (_config.policy.mode == "full" || _config.policy.mode == "allow") && len(_config.policy.hostPorts) > 0 {
				fromEndpoints: [{matchLabels: {
					(_podNamespace): "kube-system"
					"k8s:k8s-app":   "konnectivity-agent"
				}}]
				toPorts: [{ports: [for hp in _config.policy.hostPorts {port: "\(hp.port)", protocol: hp.protocol}]}]
			},
		]
		// A namespace that denies ingress and has no allow at all denies everything: one
		// empty rule.
		if _config.policy.mode != "allow" {
			ingress: [if _config.policy.mode != "host" && len(_ingress) == 0 {{}}, for r in _ingress {r}]
		}

		if _config.policy.mode == "full" {
			egress: _egress
		}

		// An allow namespace is denied by the tenant-wide policy, which also
		// opens DNS. It gets a rule section only for what its packages allow,
		// and no section at all when they allow nothing.
		if _config.policy.mode == "allow" {
			if len(_ingress) > 0 {
				ingress: _ingress
			}
			if len(_requiresEgress) > 0 {
				egress: _requiresEgress
			}
		}
		_egress: [
			// DNS, to the DNS workload only.
			{
				toEndpoints: [{matchLabels: {
					(_podNamespace): "kube-system"
					"k8s:k8s-app":   "kube-dns"
				}}]
				toPorts: [{ports: [{port: "53", protocol: "UDP"}, {port: "53", protocol: "TCP"}]}]
			},
			{toEntities: ["kube-apiserver"]},
			for r in _requiresEgress {r},
		]
		// A capability this namespace requires: its provider's namespace,
		// on the pod port.
		_requiresEgress: [
			for req in _config.policy.requires {
				toEndpoints: [{matchLabels: (_podNamespace): req.provider.namespace}]
				toPorts: [{ports: [{port: "\(req.provider.port)", protocol: req.provider.protocol}]}]
			},
		]
	}
}
