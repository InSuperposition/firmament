package templates

// The identity a tenant's charts install as. The account lives in the
// namespace Flux runs in, because a HelmRelease resolves serviceAccountName
// in its own namespace.
#InstallerAccount: {
	_config: {
		name:      string
		namespace: string
	}

	apiVersion: "v1"
	kind:       "ServiceAccount"
	metadata: {
		name:      _config.name
		namespace: _config.namespace
	}
}

// Grants the installer the built-in admin role inside the tenant namespace
// and nowhere else, so a chart cannot create a cluster-scoped object.
#InstallerRoleBinding: {
	_config: {
		name:             string
		namespace:        string
		accountNamespace: string
	}

	apiVersion: "rbac.authorization.k8s.io/v1"
	kind:       "RoleBinding"
	metadata: {
		name:      _config.name
		namespace: _config.namespace
	}
	roleRef: {
		apiGroup: "rbac.authorization.k8s.io"
		kind:     "ClusterRole"
		name:     "admin"
	}
	subjects: [{
		kind:      "ServiceAccount"
		name:      _config.name
		namespace: _config.accountNamespace
	}]
}
