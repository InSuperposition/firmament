package templates

// The namespaces the network policy covers, each with what `inputs.cue`
// resolved from the bindings and the packages: the capabilities its packages
// provide and who consumes them, the capabilities they require and who
// provides them, and the pod ports the node and the API server reach.
#Config: {
	// The instance name and namespace Timoni supplies; the policies are
	// rendered into the namespaces they cover.
	metadata: {
		name:      string
		namespace: string
	}

	namespaces!: {[#Name]: #NamespacePolicy}

	// The namespaces the tenant-wide default-deny leaves alone: those of the
	// platform tenant and the Kubernetes system namespaces. Every other
	// namespace is denied, bound or not.
	excludedNamespaces!: [...#Name]
}

#Name:     =~"^[a-z][a-z0-9-]*$"
#Port:     int & >=1 & <=65535
#Protocol: "TCP" | "UDP"

#NamespacePolicy: close({
	// full: ingress and egress default-deny and every allow. ingress: ingress
	// default-deny, every allow and the namespace's own pods; egress stays
	// open. host: only the allow for the node and the API server. allow: only
	// the allows; the tenant-wide default-deny supplies the deny and DNS.
	mode: "full" | "ingress" | "host" | "allow"
	provides: [...close({
		capability: string
		port:       #Port
		protocol:   #Protocol
		consumers: [...#Name]
	})]
	requires: [...close({
		capability: string
		provider: close({
			namespace: #Name
			port:      #Port
			protocol:  #Protocol
		})
	})]
	hostPorts: [...close({
		port:     #Port
		protocol: #Protocol
	})]
	clusterPorts: [...close({
		port:     #Port
		protocol: #Protocol
	})]
})

#Instance: {
	config: #Config

	objects: {
		// Cilium's allow-localhost: policy, which closes the node's access to
		// every pod, as a second values source of the Cilium release. It is
		// applied with the policies that keep the node's probes working, and
		// the release upgrades only after they exist.
		"cilium-values-policy": #HostPolicyValues & {_config: namespace: config.metadata.namespace}
		"tenant-default-deny": #TenantDefaultDeny & {_config: excluded: config.excludedNamespaces}
		for nsName, policy in config.namespaces {
			let rendered = #Policy & {_config: {name: nsName, "policy": policy}}
			if rendered.spec.ingress != _|_ || rendered.spec.egress != _|_ {
				"policy-\(nsName)": rendered
			}
		}
	}
}
