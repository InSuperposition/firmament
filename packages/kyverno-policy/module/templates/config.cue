package templates

#Name: =~"^[a-z][a-z0-9-]*$"

// The admission policies of one environment.
#Config: {
	// The instance name and namespace Timoni supplies; a ClusterPolicy is cluster-scoped and ignores them.
	metadata: {
		name:      string
		namespace: string
	}

	// Audit reports a violation; Enforce refuses the pod.
	mode!: "Audit" | "Enforce"

	// The tenants whose namespaces the policies leave alone.
	platformTenants!: [...#Name]

	// Who must have signed a tenant's images, checked keyless with cosign.
	// Both are anchored regular expressions.
	signer!: {
		issuer!:   =~"^\\^.+\\$$"
		identity!: =~"^\\^.+\\$$"
	}
}

#Instance: {
	config: #Config

	objects: {
		"require-signed-images": #RequireSignedImages & {_config: {
			mode:            config.mode
			platformTenants: config.platformTenants
			signer:          config.signer
		}}
	}
}
