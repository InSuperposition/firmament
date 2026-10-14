package main

import "firmament.dev/firmament:inputs"

// One environment's admission policies, rendered apart from the namespaces:
// a ClusterPolicy needs the Kyverno CRDs, which arrive with the engine release
// that the workloads tree installs, so Flux applies this tree after it.
bundle: {
	_environment: string @timoni(runtime:string:ENVIRONMENT)

	apiVersion: "v1alpha1"
	name:       "firmament-admission"

	instances: "kyverno-policy": {
		module: url: "file://../modules/kyverno-policy"
		namespace: "flux-system"
		values: {
			mode:            inputs.admission[_environment].mode
			platformTenants: inputs.admission[_environment].platformTenants
			signer:          inputs.admission[_environment].signer
		}
	}
}
