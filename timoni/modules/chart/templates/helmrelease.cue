package templates

// The release. Pruning is disabled so removing a binding never uninstalls a
// chart and the data in it; removal takes an explicit teardown.
#HelmRelease: {
	_config: {
		name:            string
		namespace:       string
		targetNamespace: string
		// Absent, the release installs with the controller's authority.
		serviceAccountName?: string
	}

	apiVersion: "helm.toolkit.fluxcd.io/v2"
	kind:       "HelmRelease"
	metadata: {
		name:      _config.name
		namespace: _config.namespace
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		interval:         "1h"
		releaseName:      _config.name
		if _config.serviceAccountName != _|_ {serviceAccountName: _config.serviceAccountName}
		targetNamespace:  _config.targetNamespace
		storageNamespace: _config.targetNamespace
		chartRef: {
			kind: "OCIRepository"
			name: _config.name
		}
		valuesFrom: [{
			kind:      "ConfigMap"
			name:      "\(_config.name)-values"
			valuesKey: "values.yaml"
		}]
		install: remediation: retries: 3
		upgrade: {
			strategy: name: "RemediateOnFailure"
			remediation: {
				retries:              3
				remediateLastFailure: true
			}
		}
	}
}
