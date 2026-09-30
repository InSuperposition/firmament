package cluster_spec

import (
	"list"

	"github.com/insuperposition/firmament/contracts/layout"
	"github.com/insuperposition/firmament/contracts/package-spec:package_spec"
)

// What a cluster provides to the environment. A property, not a name.
#Role: "trust" | "workload"

// The kinds of tenant a shared service can admit. New kinds are added to
// the enum; existing data never changes meaning.
#TenantKind: "cluster" | "team" | "customer"

// cluster.yaml: the cluster's behavior. It never names an environment,
// and never holds an environment fact (sizes, addresses, CIDRs).
#Cluster: {
	role!: #Role
	mesh: member: *true | bool
	// Tenant kinds this cluster's shared services admit; a workload
	// cluster admits none.
	tenancy: kinds: [...#TenantKind]
	requires: [...package_spec.#Requirement]
	provides: [...package_spec.#Provision]
}

// packages.yaml: the packages the cluster runs, as an unordered set. Order
// comes from requires and provides, never from this list. bootstrap marks
// a package applied once, before delivery takes over.
#Packages: {
	packages!: [...{
		name!:     layout.#PackageName
		bootstrap: *false | bool
	}]
	_uniqueNames: list.UniqueItems & [for p in packages {p.name}]
}
