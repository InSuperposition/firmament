@extern(embed)
package inputs

import (
	"strings"

	bindingsspec "firmament.dev/firmament/contracts/bindings-spec:bindingsspec"
	environmentspec "firmament.dev/firmament/contracts/environment:environment"
	packagespec "firmament.dev/firmament/contracts/package-spec:packagespec"
	openbaoconfig "firmament.dev/firmament/packages/openbao/config:openbaoconfig"
	tenantspec "firmament.dev/firmament/contracts/tenant-spec:tenantspec"
)

// Every data file the render reads, keyed by the names its path carries.
_environmentFiles: _ @embed(glob=environments/*/environment.yaml)
_tenantFiles:      _ @embed(glob=environments/*/tenants/*.yaml)
_bindingFiles:     _ @embed(glob=clusters/*/packages.yaml)
_packageFiles:     _ @embed(glob=packages/*/package.yaml)
_valuesFiles:      _ @embed(glob=clusters/*/values/*.yaml)
_openbaoFiles:     _ @embed(glob=clusters/*/openbao.yaml)

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

// OpenBao's data sections by cluster: clusters/<cluster>/openbao.yaml.
openbaoData: {[string]: openbaoconfig.#Config}
openbaoData: {
	for path, data in _openbaoFiles {
		(strings.Split(path, "/")[1]): data
	}
}

// What a package's generator adds to its values file, by environment and
// package. Every bound package has an entry, empty unless it has a generator.
// A values file that sets a key the generator sets is refused, naming it.
_generatedValues: {[string]: {[string]: {...}}}
_generatedValues: {
	for envName, env in environments {
		(envName): {
			for binding in bindings[env.cluster] {
				(binding.package): {}
			}
		}
	}
}
_generatedValues: {
	for envName, env in environments for binding in bindings[env.cluster] if binding.package == "openbao" {
		(envName): openbao: openbaoRendered[envName].values
	}
}

// OpenBao's rendered config by environment. A regular field, not a hidden
// one, so vetting the package also checks the cross-references it holds.
openbaoRendered: {[string]: openbaoconfig.#Render}
openbaoRendered: {
	for envName, env in environments for binding in bindings[env.cluster] if binding.package == "openbao" {
		(envName): {
			config:    openbaoData[env.cluster]
			namespace: binding.namespace
		}
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
					values:          chartValues[env.cluster][binding.package] & _generatedValues[envName][binding.package]
				}
			}
		}
	}
}
