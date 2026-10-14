package templates

// Default-deny for every namespace the platform tenant does not own, in both
// directions, with DNS the only way out. It selects by exclusion, so a
// namespace whose binding was removed, or one made by hand, stays denied.
// Cilium combines it additively with each namespace's own allows.
#TenantDefaultDeny: {
	_config: excluded: [...#Name]

	apiVersion: "cilium.io/v2"
	kind:       "CiliumClusterwideNetworkPolicy"
	metadata: {
		name: "tenant-default-deny"
		// Removing a binding never lifts the deny.
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		// NotIn alone also matches an endpoint without the key, such as the
		// reserved ingress endpoint of the Gateway; Exists keeps it out.
		endpointSelector: matchExpressions: [{
			key:      "io.kubernetes.pod.namespace"
			operator: "NotIn"
			values:   _config.excluded
		}, {
			key:      "io.kubernetes.pod.namespace"
			operator: "Exists"
		}]
		enableDefaultDeny: {ingress: true, egress: true}
		ingress: [{}]
		egress: [{
			toEndpoints: [{matchLabels: {
				"k8s:io.kubernetes.pod.namespace": "kube-system"
				"k8s:k8s-app":                     "kube-dns"
			}}]
			toPorts: [{ports: [{port: "53", protocol: "UDP"}, {port: "53", protocol: "TCP"}]}]
		}]
	}
}
