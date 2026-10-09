package templates

import (
	packagespec "firmament.dev/package-spec:packagespec"
)

// One chart package placed in a cluster. The instance is named after the
// package and lives in the namespace Flux runs in; the chart installs into
// targetNamespace, which a binding names.
#Config: {
	metadata: {
		name:      string
		namespace: string
	}

	package!:         packagespec.#Package
	targetNamespace!: =~"^[a-z][a-z0-9-]*$"
	// The chart's values, written to one ConfigMap the HelmRelease reads.
	values!: {...}

	// A chart is installed under the name of its package, so the instance
	// and the package cannot disagree.
	metadata: name: package.name
}

#Instance: {
	config: #Config

	objects: {
		source: #OCIRepository & {_config: {
			name:      config.package.name
			namespace: config.metadata.namespace
			source:    config.package.pin.source
			digest:    config.package.pin.digest
		}}
		values: #ValuesConfigMap & {_config: {
			name:      config.package.name
			namespace: config.metadata.namespace
			values:    config.values
		}}
		release: #HelmRelease & {_config: {
			name:            config.package.name
			namespace:       config.metadata.namespace
			targetNamespace: config.targetNamespace
		}}
	}
}
