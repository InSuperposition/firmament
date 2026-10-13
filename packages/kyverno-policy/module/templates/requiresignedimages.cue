package templates

// Every image of a pod in a tenant namespace must carry a keyless cosign
// signature from the configured signer. A namespace is a tenant namespace
// when it has the tenant label and the label does not name a platform tenant;
// a namespace without the label is not covered. The rule names every image
// (*), so an image from any registry that the signer did not sign is refused.
#RequireSignedImages: {
	_config: {
		mode: "Audit" | "Enforce"
		platformTenants: [...#Name]
		signer: {issuer: string, identity: string}
	}

	apiVersion: "kyverno.io/v1"
	kind:       "ClusterPolicy"
	metadata: {
		name: "require-signed-images"
		// Removing a binding never lifts the policy.
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		background: false
		rules: [{
			name: "signed-by-the-signer"
			match: any: [{resources: {
				kinds: ["Pod"]
				namespaceSelector: matchExpressions: [{
					key:      "firmament.dev/tenant"
					operator: "Exists"
				}, {
					key:      "firmament.dev/tenant"
					operator: "NotIn"
					values:   _config.platformTenants
				}]
			}}]
			verifyImages: [{
				imageReferences: ["*"]
				failureAction:  _config.mode
				required:       true
				verifyDigest:   true
				mutateDigest:   false
				attestors: [{entries: [{keyless: {
					issuerRegExp:  _config.signer.issuer
					subjectRegExp: _config.signer.identity
					rekor: url: "https://rekor.sigstore.dev"
				}}]}]
			}]
		}]
	}
}
