@extern(embed)
package inputs

import (
	"strings"

	bindingsspec "firmament.dev/firmament/contracts/bindings-spec:bindingsspec"
	environmentspec "firmament.dev/firmament/contracts/environment:environment"
	packagespec "firmament.dev/firmament/contracts/package-spec:packagespec"
	tenantspec "firmament.dev/firmament/contracts/tenant-spec:tenantspec"
)

// Every data file the render reads, keyed by the names its path carries.
_environmentFiles: _ @embed(glob=environments/*/environment.yaml)
_tenantFiles:      _ @embed(glob=environments/*/tenants/*.yaml)
_bindingFiles:     _ @embed(glob=clusters/*/packages.yaml)
_packageFiles:     _ @embed(glob=packages/*/package.yaml)
_valuesFiles:      _ @embed(glob=clusters/*/values/*.yaml)

// A package is named by its folder.
packages: {[string]: packagespec.#Package}
packages: {
	for path, data in _packageFiles {
		(strings.Split(path, "/")[1]): data & {name: strings.Split(path, "/")[1]}
	}
}

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

// A binding names a package that exists and a tenant its environment
// defines, and one namespace has one tenant. Referencing them makes a
// missing one an error that names it.
for envName, env in environments for binding in bindings[env.cluster] {
	packageDefined: (envName): (binding.package): packages[binding.package]
	tenantDefined: (envName): (binding.tenant):   tenants[envName][binding.tenant]
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

// A cluster's chart values: clusters/<cluster>/values/<package>.yaml.
chartValues: {[string]: {[string]: {...}}}
chartValues: {
	for path, data in _valuesFiles {
		(strings.Split(path, "/")[1]): (strings.TrimSuffix(strings.Split(path, "/")[3], ".yaml")): data
	}
}

// The packages the bootstrap installs once and Flux then adopts. A field that
// is optional in a package.yaml cannot be referenced, so they are collected
// by iterating the fields.
_bootstrapPackages: {
	for name, package in packages for key, value in package if key == "bootstrap" && value == true {
		(name): true
	}
}

// The chart packages each environment installs: every bound package the
// bootstrap does not install. A chart package needs a values file, even an
// empty one, so a missing file is an error that names the package.
charts: {[string]: {[string]: {package: packagespec.#Package, targetNamespace: string, values: {...}}}}
charts: {
	for envName, env in environments {
		(envName): {
			for binding in bindings[env.cluster] if _bootstrapPackages[binding.package] == _|_ {
				(binding.package): {
					package:         packages[binding.package]
					targetNamespace: binding.namespace
					values:          chartValues[env.cluster][binding.package]
				}
			}
		}
	}
}
