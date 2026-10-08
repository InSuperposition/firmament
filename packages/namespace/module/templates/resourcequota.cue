package templates

// The tenant's quota on one of its namespaces.
#ResourceQuota: {
	_config: {
		name: string
		quota: {
			cpu:    string
			memory: string
		}
	}

	apiVersion: "v1"
	kind:       "ResourceQuota"
	metadata: {
		name:      "tenant"
		namespace: _config.name
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: hard: {
		"requests.cpu":    _config.quota.cpu
		"requests.memory": _config.quota.memory
	}
}
