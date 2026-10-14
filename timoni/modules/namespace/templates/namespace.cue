package templates

// The namespace and its labels. A namespace of a tenant that is not the
// platform tenant enforces the baseline Pod Security Standard, which the API
// server applies with no webhook to fail. Pruning is disabled so removing a binding
// never deletes a namespace and the workloads in it.
#Namespace: {
	_config: {
		environment: string
		name:        string
		tenant:      string
		kind:        string
	}

	apiVersion: "v1"
	kind:       "Namespace"
	metadata: {
		name: _config.name
		labels: {
			"firmament.dev/tenant":      _config.tenant
			"firmament.dev/environment": _config.environment
			if _config.kind != "platform" {"pod-security.kubernetes.io/enforce": "baseline"}
		}
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
}
