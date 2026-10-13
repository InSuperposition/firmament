package templates

// No pod in a tenant namespace may carry an ephemeral container. The image
// policy checks a pod's own containers, and Kyverno 1.19.1 admits an
// ephemeral container without evaluating a policy that lists the
// pods/ephemeralcontainers subresource, so the subresource is refused outright.
// The tenant selection is the one of the image policy.
#DenyEphemeralContainers: {
	_config: platformTenants: [...#Name]

	apiVersion: "policies.kyverno.io/v1"
	kind:       "ValidatingPolicy"
	metadata: {
		name: "deny-ephemeral-containers"
		// Removing a binding never lifts the policy.
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		validationActions: ["Deny"]
		// Admission only: a background scan would need Kyverno to read the
		// subresource, which it has no permission for, and left the policy
		// reported as not ready in a live run.
		evaluation: background: enabled: false
		matchConstraints: {
			namespaceSelector: matchExpressions: [{
				key:      "firmament.dev/tenant"
				operator: "Exists"
			}, {
				key:      "firmament.dev/tenant"
				operator: "NotIn"
				values:   _config.platformTenants
			}]
			resourceRules: [{
				apiGroups: [""]
				apiVersions: ["v1"]
				operations: ["CREATE", "UPDATE"]
				resources: ["pods", "pods/ephemeralcontainers"]
			}]
		}
		validations: [{
			expression: "!has(object.spec.ephemeralContainers) || size(object.spec.ephemeralContainers) == 0"
			message:    "ephemeral containers are not allowed in tenant namespaces"
		}]
	}
}
