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

	for nsName, tenantName in namespaces {
		_tenantDefined: (nsName): tenants[tenantName]
	}
}

#Instance: {
	config: #Config

	objects: {
		for nsName, tenantName in config.namespaces {
			"namespace-\(nsName)": #Namespace & {
				_config: {environment: config.environment, name: nsName, tenant: tenantName}
			}
			"resourcequota-\(nsName)": #ResourceQuota & {
				_config: {name: nsName, quota: config.tenants[tenantName].quota}
			}
		}
	}
}
