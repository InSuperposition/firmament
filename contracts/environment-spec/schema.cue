package environment_spec

import (
	"list"

	"github.com/insuperposition/firmament/contracts/layout"
	"github.com/insuperposition/firmament/contracts/environment-facts:environment_facts"
	"github.com/insuperposition/firmament/contracts/cluster-spec:cluster_spec"
)

// Where the environment's machines run.
#Target: "orbstack" | "cloud" | "bare-metal" | "edge"

// One machine of a cluster. role is the k0s role hint the orchestrator
// uses.
#MachineSpec: {
	environment_facts.#Machine
	role: *"controller+worker" | "controller" | "worker"
}

// environment.yaml: the facts of one deployment context. Credentials are
// named here and their files are listed in private-state; no value is
// ever written in this file.
#Environment: {
	target!: #Target
	engine!: "flux"
	// Where enrolled clusters pull the rendered artifacts from.
	artifact_source!: url!: =~"^oci://[^[:space:]]+$"
	// The hardware the environment may use in total.
	budget!: environment_facts.#Machine
	clusters!: [layout.#Name]: {
		machines!: [#MachineSpec, ...#MachineSpec]
		service_cidr!: environment_facts.#CIDR
	}
	// Mesh ids and pod CIDRs, one per cluster ever created here. Entries
	// are append-only: contracts:lint fails when one changes or disappears
	// against the last commit, so a retired cluster keeps its allocation.
	mesh!: allocations!: [layout.#Name]: {
		id!:       environment_facts.#MeshID
		pod_cidr!: environment_facts.#CIDR
	}
	credentials: [=~"^[a-z][a-z0-9-]*$"]: private_state!: =~"^[^/][^[:space:]]*$"

	// Every cluster has a mesh allocation (a missing one fails as
	// mesh.allocations.<cluster>.id: field is required), and no two
	// allocations share an id.
	for c, _ in clusters {mesh: allocations: (c): _}
	_uniqueIDs: list.UniqueItems & [for _, a in mesh.allocations {a.id}]
	// The machines fit the budget. CPUs may be shared, memory and disk
	// may not.
	_machineMemoryFitsBudget: list.Sum([for _, c in clusters for m in c.machines {m.memory_mib}]) & <=budget.memory_mib
	_machineDiskFitsBudget: list.Sum([for _, c in clusters for m in c.machines {m.disk_gib}]) & <=budget.disk_gib
}

// tenants/<name>.yaml: one tenant admitted to the environment's shared
// services. The file name is the tenant name.
#Tenant: {
	kind!: cluster_spec.#TenantKind
}

// deltas/<cluster>/<package>.yaml: a sparse divergence from the cluster's
// values, with the reason for it. Only keys the package lists in
// delta_keys may appear; contracts:lint checks them against package.yaml.
#Delta: {
	reason!: string & !=""
	values!: {...}
}
