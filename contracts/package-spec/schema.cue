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
	// Pod ports that any pod in the cluster may reach, such as the DNS
	// workload's. The network policy allows the cluster entity on exactly
	// these.
	cluster_ports?: [...#HostPort]
	// Pod ports that the platform Gateway's Envoy reaches. The network
	// policy allows the ingress entity on exactly these.
	ingress_ports?: [...#HostPort]
	// Who must have signed the chart, checked keyless with cosign by Flux
	// before the chart is used. Absent: the digest pin is the only check.
	verify?: #Verify
})

// Both fields are regular expressions Flux matches against the signing
// certificate. They must be anchored, so a partial match cannot pass.
#Verify: close({
	// The OIDC issuer of the signing certificate.
	issuer!: =~"^\\^.+\\$$"
	// The identity (the certificate subject) that signed the chart.
	identity!: =~"^\\^.+\\$$"
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
