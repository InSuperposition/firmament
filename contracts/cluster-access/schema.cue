package cluster_access

import (
	"github.com/insuperposition/firmament/contracts/layout"
	"github.com/insuperposition/firmament/contracts/environment-facts:environment_facts"
	"github.com/insuperposition/firmament/contracts/cluster-spec:cluster_spec"
)

// How to reach one installed cluster. The orchestrator writes it; the
// bootstrap, the engine and the checks read it. The labels are what a
// fleet manager (k0rdent) needs to adopt the cluster.
#ClusterAccess: {
	cluster!: layout.#Name
	api!: {
		host!: environment_facts.#IPv4
		port:  *6443 | environment_facts.#Port
	}
	// The kubeconfig, by the name private-state lists it under.
	kubeconfig!: =~"^[a-z][a-z0-9-]*$"
	labels!: {
		role!:        cluster_spec.#Role
		environment!: layout.#Name
	}
}
