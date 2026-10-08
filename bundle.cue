package main

import "firmament.dev/firmament:inputs"

// One environment's rendered output. The environment comes from the
// ENVIRONMENT variable (timoni --runtime-from-env); unknown names fail here.
bundle: {
	_environment: string @timoni(runtime:string:ENVIRONMENT)

	apiVersion: "v1alpha1"
	name:       "firmament"

	instances: {
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
