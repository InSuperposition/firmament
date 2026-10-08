package templates

// The namespace and its labels. Pruning is disabled so removing a binding
// never deletes a namespace and the workloads in it.
#Namespace: {
	_config: {
		environment: string
		name:        string
		tenant:      string
	}

	apiVersion: "v1"
	kind:       "Namespace"
	metadata: {
		name: _config.name
		labels: {
			"firmament.dev/tenant":      _config.tenant
			"firmament.dev/environment": _config.environment
		}
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
}
