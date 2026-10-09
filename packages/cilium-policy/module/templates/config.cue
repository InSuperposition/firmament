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
}

#Name:     =~"^[a-z][a-z0-9-]*$"
#Port:     int & >=1 & <=65535
#Protocol: "TCP" | "UDP"

#NamespacePolicy: close({
	// An enforced namespace gets the default-deny and every allow; any other
	// gets only the allow for the node and the API server.
	enforce: bool
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
})

#Instance: {
	config: #Config

	objects: {
		// Cilium's allow-localhost: policy, which closes the node's access to
		// every pod, as a second values source of the Cilium release. It is
		// applied with the policies that keep the node's probes working, and
		// the release upgrades only after they exist.
		"cilium-values-policy": #HostPolicyValues & {_config: namespace: config.metadata.namespace}
		for nsName, policy in config.namespaces {
			"policy-\(nsName)": #Policy & {_config: {name: nsName, "policy": policy}}
		}
	}
}
