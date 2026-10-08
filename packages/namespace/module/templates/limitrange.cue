package templates

// Default requests for containers that declare none. A ResourceQuota on
// requests refuses any pod whose containers omit them, and charts such as
// Cilium set none.
#LimitRange: {
	_config: name: string

	apiVersion: "v1"
	kind:       "LimitRange"
	metadata: {
		name:      "tenant-defaults"
		namespace: _config.name
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: limits: [{
		type: "Container"
		defaultRequest: {
			cpu:    "50m"
			memory: "64Mi"
		}
	}]
}
