package templates

// One CiliumNetworkPolicy per covered namespace. A rule section on both
// ingress and egress makes Cilium deny everything else, so the default-deny
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
			if _config.policy.enforce && len(_config.policy.hostPorts) > 0 {
				fromEndpoints: [{matchLabels: {
					(_podNamespace): "kube-system"
					"k8s:k8s-app":   "konnectivity-agent"
				}}]
				toPorts: [{ports: [for hp in _config.policy.hostPorts {port: "\(hp.port)", protocol: hp.protocol}]}]
			},
		]
		// An enforced namespace with no allow at all denies everything: one
		// empty rule.
		ingress: [if _config.policy.enforce && len(_ingress) == 0 {{}}, for r in _ingress {r}]

		if _config.policy.enforce {
			egress: _egress
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
			// A capability this namespace requires: its provider's namespace,
			// on the pod port.
			for req in _config.policy.requires {
				toEndpoints: [{matchLabels: (_podNamespace): req.provider.namespace}]
				toPorts: [{ports: [{port: "\(req.provider.port)", protocol: req.provider.protocol}]}]
			},
		]
	}
}
