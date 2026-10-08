@extern(embed)
package inputs

import (
	"strings"

	bindingsspec "firmament.dev/firmament/contracts/bindings-spec:bindingsspec"
	environmentspec "firmament.dev/firmament/contracts/environment:environment"
	tenantspec "firmament.dev/firmament/contracts/tenant-spec:tenantspec"
)

// Every data file the render reads, keyed by the names its path carries.
_environmentFiles: _ @embed(glob=environments/*/environment.yaml)
_tenantFiles:      _ @embed(glob=environments/*/tenants/*.yaml)
_bindingFiles:     _ @embed(glob=clusters/*/packages.yaml)

environments: {[string]: environmentspec.#Environment}
environments: {
	for path, data in _environmentFiles {
		(strings.Split(path, "/")[1]): data
	}
}

tenants: {[string]: {[string]: tenantspec.#Tenant}}
tenants: {
	for path, data in _tenantFiles {
		(strings.Split(path, "/")[1]): (strings.TrimSuffix(strings.Split(path, "/")[3], ".yaml")): data
	}
}

bindings: {[string]: bindingsspec.#Contract}
bindings: {
	for path, data in _bindingFiles {
		(strings.Split(path, "/")[1]): data
	}
}

// A binding names a tenant its environment defines, and one namespace has
// one tenant. Referencing the tenant makes a missing one an error that names it.
for envName, env in environments for binding in bindings[env.cluster] {
	tenantDefined: (envName): (binding.tenant): tenants[envName][binding.tenant]
}

// The namespaces each environment declares, with their tenant.
namespaces: {[string]: {[string]: string}}
namespaces: {
	for envName, env in environments {
		(envName): {
			for binding in bindings[env.cluster] {
				(binding.namespace): binding.tenant
			}
		}
	}
}
