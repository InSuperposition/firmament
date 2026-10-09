package packagespec

// The package.yaml format: what one package is, what it requires and
// provides, and which delta keys it accepts. Closed: a field not declared
// here is refused, and a namespace is not a field because bindings place a
// package (C70). contracts:lint checks the sample against #Contract.
#Contract: #Package

#Name: =~"^[a-z][a-z0-9-]*$"

#Package: close({
	name!:  #Name
	layer!: #Name
	pin!: close({
		source!:  string & !=""
		version!: string & !=""
		digest!:  =~"^sha256:[a-f0-9]{64}$"
	})
	bootstrap?: bool
	// Keys an environment delta may set; a delta naming another key is refused.
	delta_keys?: [...string & !=""]
	requires?: [...#Requirement]
	provides?: [...#Provision]
	// Pod ports that the node (kubelet probes) and the API server (admission
	// webhooks) reach. The network policy allows the host and the
	// kube-apiserver entities on exactly these.
	host_ports?: [...#HostPort]
})

#HostPort: close({
	port!:     int & >=1 & <=65535
	protocol!: "TCP" | "UDP"
})

#Scope: "cluster" | "mesh"

#Requirement: close({
	capability!: #Name
	scope!:      #Scope
})

#Provision: close({
	capability!: #Name
	scope!:      #Scope
	// The port the pod listens on, not a Service port that maps to it:
	// Cilium matches the pod port after service translation.
	port!:     int & >=1 & <=65535
	protocol!: "TCP" | "UDP"
	readiness!: close({
		kind!: string & !=""
		name!: string & !=""
	})
})
