package main

import "firmament.dev/firmament:inputs"

// One environment's rendered output. The environment comes from the
// ENVIRONMENT variable (timoni --runtime-from-env); unknown names fail here.
bundle: {
	_environment: string @timoni(runtime:string:ENVIRONMENT)
	// The chart packages this environment installs.
	_environmentCharts: inputs.charts[_environment]

	apiVersion: "v1alpha1"
	name:       "firmament"

	instances: {
		// One instance of the chart module per chart package the environment
		// installs; the instance is named after the package.
		for name, chart in _environmentCharts {
			(name): {
				module: url: "file://../modules/chart"
				namespace: "flux-system"
				values: {
					package:         chart.package
					targetNamespace: chart.targetNamespace
					values:          chart.values
					for key, value in chart if key == "serviceAccountName" {serviceAccountName: value}
				}
			}
		}

		// The network policy of the namespaces inputs.cue selects.
		"cilium-policy": {
			module: url: "file://../modules/cilium-policy"
			namespace: "flux-system"
			values: {
				namespaces:         inputs.policy[_environment].namespaces
				excludedNamespaces: inputs.policy[_environment].excludedNamespaces
			}
		}

		namespace: {
			module: url: "file://../modules/namespace"
			namespace: "flux-system"
			values: {
				environment: _environment
				tenants:     inputs.tenants[_environment]
				namespaces:  inputs.namespaces[_environment]
				installers:  inputs.installers[_environment]
			}
		}
	}
}
