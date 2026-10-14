package templates

// The chart, pinned by digest. A tag is never rendered: the digest is the
// only thing the pin carries into the cluster. Moving the packages to another
// source never prunes the chart source.
#OCIRepository: {
	_config: {
		name:      string
		namespace: string
		source:    string
		digest:    string
		// Who must have signed the chart. Absent: no signature check.
		verify?: {issuer: string, identity: string}
	}

	apiVersion: "source.toolkit.fluxcd.io/v1"
	kind:       "OCIRepository"
	metadata: {
		name:      _config.name
		namespace: _config.namespace
		annotations: "kustomize.toolkit.fluxcd.io/prune": "disabled"
	}
	spec: {
		interval: "1h"
		url:      _config.source
		ref: digest: _config.digest
		if _config.verify != _|_ {
			verify: {
				provider: "cosign"
				matchOIDCIdentity: [{
					issuer:  _config.verify.issuer
					subject: _config.verify.identity
				}]
			}
		}
		layerSelector: {
			mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
			operation: "copy"
		}
	}
}
