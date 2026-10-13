package templates

// Every image of a pod in a tenant namespace must carry a keyless cosign
// signature from the configured signer. A namespace is a tenant namespace
// when it has the tenant label and the label does not name a platform tenant;
// a namespace without the label is not covered. The policy names every image
// (*), so an image from any registry that the signer did not sign is refused.
// An ImageValidatingPolicy, not a ClusterPolicy: Kyverno's ClusterPolicy
// cannot find a cosign v3 bundle stored as an OCI referrer.
#RequireSignedImages: {
	_config: {
		mode: "Audit" | "Deny"
		platformTenants: [...#Name]
		signer: {issuer: string, identity: string}
	}

	apiVersion: "policies.kyverno.io/v1"
	kind:       "ImageValidatingPolicy"
	metadata: {
		name: "require-signed-images"
		// Removing a binding never lifts the policy.
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		validationActions: [_config.mode]
		// Keyless verification of an image from a registry that has no
		// cached result takes up to 12 s in a live run; the default 10 s
		// timeout would fail the pod with an internal error instead of a
		// refusal.
		webhookConfiguration: timeoutSeconds: 30
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
				resources: ["pods"]
			}]
		}
		matchImageReferences: [{glob: "*"}]
		attestors: [{
			name: "signer"
			cosign: {
				keyless: identities: [{
					issuerRegExp:  _config.signer.issuer
					subjectRegExp: _config.signer.identity
				}]
				ctlog: url: "https://rekor.sigstore.dev"
			}
		}]
		validations: [{
			expression: "images.containers.map(image, verifyImageSignatures(image, [attestors.signer])).all(e, e > 0)"
			message:    "every container image must be signed by the signer"
		}]
	}
}
