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
		for nsName, policy in config.namespaces {
			"policy-\(nsName)": #Policy & {_config: {name: nsName, "policy": policy}}
		}
	}
}
