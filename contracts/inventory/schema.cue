package inventory

import (
	packagespec "firmament.dev/firmament/contracts/package-spec:packagespec"
	tenantspec "firmament.dev/firmament/contracts/tenant-spec:tenantspec"
)

// The inventory of one environment: who owns each bound namespace, what runs
// in it and where the chart came from. Generated from the tenants, bindings
// and packages by render/inventory.cue, never edited. Closed: a field not
// declared here is refused. contracts:lint checks the sample against
// #Contract.
#Contract: #Inventory

#Name: =~"^[a-z][a-z0-9-]*$"

#Inventory: close({
	environment!: #Name
	// One entry per bound namespace, keyed by the namespace name.
	namespaces!: {[#Name]: #Namespace}
})

#Namespace: close({
	tenant!:         #Name
	kind!:           "platform" | "team" | "customer"
	administrators!: [...string & !=""]
	quota!: close({
		cpu!:    tenantspec.#Quantity
		memory!: tenantspec.#Quantity
	})
	// Every package bound to the namespace, in binding order.
	packages!: [#Package, ...#Package]
})

#Package: close({
	name!:    #Name
	layer!:   #Name
	source!:  string & !=""
	version!: string & !=""
	digest!:  =~"^sha256:[a-f0-9]{64}$"
	// Installed by the bootstrap, then adopted by Flux.
	bootstrap!: bool
	// The package.yaml carries a verify block, so Flux checks the chart's
	// keyless signature before using it.
	signed!:       bool
	hostPorts!:    [...packagespec.#HostPort]
	ingressPorts!: [...packagespec.#HostPort]
})
