package templates

import (
	tenantspec "firmament.dev/tenant-spec:tenantspec"
)

// The namespaces one environment declares, each with the tenant that owns
// it. A namespace naming a tenant the environment does not define is refused.
#Config: {
	// The instance name and namespace Timoni supplies; the module renders cluster-scoped objects and ignores them.
	metadata: {
		name:      string
		namespace: string
	}

	environment!: =~"^[a-z][a-z0-9-]*$"
	tenants!: {[string]: tenantspec.#Tenant}
	namespaces!: {[string]: string}
	// The installer account of each namespace whose charts do not run with the controller's authority.
	installers!: {[string]: string}

	for nsName, tenantName in namespaces {
		_tenantDefined: (nsName): tenants[tenantName]
	}
	for nsName, _ in installers {
		_namespaceDeclared: (nsName): namespaces[nsName]
	}
}

#Instance: {
	config: #Config

	objects: {
		for nsName, tenantName in config.namespaces {
			"namespace-\(nsName)": #Namespace & {
				_config: {environment: config.environment, name: nsName, tenant: tenantName, kind: config.tenants[tenantName].kind}
			}
			"limitrange-\(nsName)": #LimitRange & {
				_config: name: nsName
			}
			"resourcequota-\(nsName)": #ResourceQuota & {
				_config: {name: nsName, quota: config.tenants[tenantName].namespace_quota}
			}
			if config.installers[nsName] != _|_ {
				"installer-\(nsName)": #InstallerAccount & {
					_config: {name: config.installers[nsName], namespace: config.metadata.namespace}
				}
				"installer-rolebinding-\(nsName)": #InstallerRoleBinding & {
					_config: {name: config.installers[nsName], namespace: nsName, accountNamespace: config.metadata.namespace}
				}
			}
		}
	}
}
