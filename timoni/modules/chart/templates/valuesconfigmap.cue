package templates

import "encoding/yaml"

// The chart's values. The watch label makes helm-controller act on a change
// at once instead of at its next interval.
#ValuesConfigMap: {
	_config: {
		name:      string
		namespace: string
		values: {...}
	}

	apiVersion: "v1"
	kind:       "ConfigMap"
	metadata: {
		name:      "\(_config.name)-values"
		namespace: _config.namespace
		labels: "reconcile.fluxcd.io/watch":              "Enabled"
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	data: "values.yaml": yaml.Marshal(_config.values)
}
