package templates

import "encoding/yaml"

// The values that switch Cilium's allow-localhost to policy, read by the
// Cilium release as an optional second values source. The watch label makes
// helm-controller act on its appearance at once.
#HostPolicyValues: {
	_config: namespace: string

	apiVersion: "v1"
	kind:       "ConfigMap"
	metadata: {
		name:      "cilium-values-policy"
		namespace: _config.namespace
		labels: "reconcile.fluxcd.io/watch":              "Enabled"
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	data: "values.yaml": yaml.Marshal({extraConfig: "allow-localhost": "policy"})
}
