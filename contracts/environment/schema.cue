package environment

import "net"

// The environment contract: the facts an environment states about itself.
// Closed, so each later fact needs a schema edit. Tenants and deltas are
// separate files with their own specs (tenant-spec, delta-spec).
#Contract: #Environment

#Name: =~"^[a-z][a-z0-9-]*$"

#Environment: close({
	// The cluster definition this environment runs: clusters/<cluster>/.
	cluster!: #Name
	target!:  "orbstack"
	engine!:  "flux"
	// Where the rendered artifacts are pulled from.
	artifact_source!: =~"^ghcr\\.io/[a-z0-9._/-]+$"
	// Mesh allocations, append-only through OpenTofu state: a removed
	// cluster stays as retired: true.
	clusters!: close({[#Name]: #Allocation})
	// The cluster this environment runs has an allocation.
	clusters: (cluster): _
	// Names only; the values live in private state.
	credentials?: [...#Name]
})

#Allocation: close({
	mesh_id!:  int & >=1
	pod_cidr!: net.IPCIDR
	retired?:  true
})
