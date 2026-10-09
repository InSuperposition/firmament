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

// ---- network policy ----------------------------------------------------

// Who provides each capability in an environment's cluster, and where. A
// capability provided twice is a conflict; a requirement nobody provides
// is refused below, naming the package and the capability.
_providerOf: {[string]: {[string]: {namespace: string, port: int, protocol: string}}}
_providerOf: {
	for envName, env in environments {
		(envName): {
			for binding in bindings[env.cluster] for key, value in packages[binding.package] if key == "provides" for provision in value {
				(provision.capability): {namespace: binding.namespace, port: provision.port, protocol: provision.protocol}
			}
		}
	}
}

requirementMet: {
	for envName, env in environments for binding in bindings[env.cluster] for key, value in packages[binding.package] if key == "requires" for requirement in value {
		(envName): (binding.package): (requirement.capability): _providerOf[envName][requirement.capability]
	}
}

// The namespaces of the packages that require each capability. A provided
// capability has an entry even when nobody requires it.
_consumerNamespaces: {[string]: {[string]: {[string]: true}}}
_consumerNamespaces: {
	for envName, env in environments {
		(envName): {
			for capability, _ in _providerOf[envName] {
				(capability): {}
			}
			for binding in bindings[env.cluster] for key, value in packages[binding.package] if key == "requires" for requirement in value {
				(requirement.capability): (binding.namespace): true
			}
		}
	}
}

// Packages that list host ports.
_hostPortPackages: {
	for name, package in packages for key, _ in package if key == "host_ports" {
		(name): true
	}
}

// The namespaces the network policy covers, and what it renders for each. A
// namespace of a trust-layer package is enforced: default-deny and every allow
// (D1 of the network-policy review). A namespace of another package that lists
// host ports gets only the allow for the node, because the node's access to
// pods is closed cluster-wide and its probes must still pass.
policy: {[string]: {namespaces: {[string]: {...}}}}
policy: {
	for envName, env in environments {
		(envName): namespaces: {
			for binding in bindings[env.cluster] if packages[binding.package].layer == "trust" || _hostPortPackages[binding.package] != _|_ {
				(binding.namespace): {
					enforce: len([for member in bindings[env.cluster] if member.namespace == binding.namespace if packages[member.package].layer == "trust" {member}]) > 0
					provides: [
						for member in bindings[env.cluster] if member.namespace == binding.namespace
						for key, value in packages[member.package] if key == "provides"
						for provision in value {
							capability: provision.capability
							port:       provision.port
							protocol:   provision.protocol
							consumers: [for consumer, _ in _consumerNamespaces[envName][provision.capability] {consumer}]
						},
					]
					requires: [
						for member in bindings[env.cluster] if member.namespace == binding.namespace
						for key, value in packages[member.package] if key == "requires"
						for requirement in value {
							capability: requirement.capability
							provider:   _providerOf[envName][requirement.capability]
						},
					]
					hostPorts: [
						for member in bindings[env.cluster] if member.namespace == binding.namespace
						for key, value in packages[member.package] if key == "host_ports"
						for hostPort in value {hostPort},
					]
				}
			}
		}
	}
}
