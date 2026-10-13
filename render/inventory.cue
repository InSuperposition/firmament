package inventory

import (
	"firmament.dev/firmament:inputs"
	inventoryschema "firmament.dev/firmament/contracts/inventory:inventory"
)

// What each package contributes to a namespace entry. A field that is
// optional in a package.yaml cannot be referenced, so the optional ones are
// collected by iterating the fields.
_package: {
	for name, package in inputs.packages {
		(name): {
			"name":    name
			layer:     package.layer
			source:    package.pin.source
			version:   package.pin.version
			digest:    package.pin.digest
			bootstrap: len([for key, value in package if key == "bootstrap" && value == true {key}]) > 0
			signed:    len([for key, _ in package if key == "verify" {key}]) > 0
			hostPorts: [for key, value in package if key == "host_ports" for port in value {port}]
			ingressPorts: [for key, value in package if key == "ingress_ports" for port in value {port}]
		}
	}
}

// The inventory of each environment, one entry per namespace its cluster
// binds. A binding naming an unknown tenant or package fails in inputs.
inventory: {[string]: inventoryschema.#Inventory}
inventory: {
	for envName, env in inputs.environments {
		(envName): {
			environment: envName
			namespaces: {
				for binding in inputs.bindings[env.cluster] {
					(binding.namespace): {
						tenant:         binding.tenant
						kind:           inputs.tenants[envName][binding.tenant].kind
						administrators: inputs.tenants[envName][binding.tenant].administrators
						quota:          inputs.tenants[envName][binding.tenant].namespace_quota
						packages: [for member in inputs.bindings[env.cluster] if member.namespace == binding.namespace {_package[member.package]}]
					}
				}
			}
		}
	}
}
