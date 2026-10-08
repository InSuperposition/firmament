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
				module: url: "file://packages/chart/module"
				namespace: "flux-system"
				values: {
					package:         chart.package
					targetNamespace: chart.targetNamespace
					values:          chart.values
				}
			}
		}

		namespace: {
			module: url: "file://packages/namespace/module"
			namespace: "flux-system"
			values: {
				environment: _environment
				tenants:     inputs.tenants[_environment]
				namespaces:  inputs.namespaces[_environment]
			}
		}
	}
}
