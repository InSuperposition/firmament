package main

import (
	templates "timoni.sh/namespace/templates"
)

values: templates.#Config

timoni: {
	apiVersion: "v1alpha1"

	instance: templates.#Instance & {
		config: values
		config: metadata: {
			name:      string @tag(name)
			namespace: string @tag(namespace)
		}
	}

	apply: app: [for obj in instance.objects {obj}]
}
