package machine_hosts

import (
	"list"

	"github.com/insuperposition/firmament/contracts/layout"
	"github.com/insuperposition/firmament/contracts/environment-facts:environment_facts"
)

// The machines a machine layer created, as the orchestrator reaches them
// over SSH. On OrbStack every machine shares the proxy address and port and
// is told apart by user (root@<machine>); address is the machine's own IP,
// which the orchestrator uses for the API endpoint.
#MachineHosts: {
	hosts!: [...{
		name!:    layout.#Name
		address!: environment_facts.#IPv4
		ssh!: {
			address!: environment_facts.#IPv4 | =~"^[a-z0-9.-]+$"
			port:     *22 | environment_facts.#Port
			user!:    =~"^[a-z_][a-z0-9_@.-]*$"
			// The private key, by the name private-state lists it under.
			key!: =~"^[a-z][a-z0-9-]*$"
		}
		role: *"controller+worker" | "controller" | "worker"
	}] & [_, ...]
	_uniqueNames: list.UniqueItems & [for h in hosts {h.name}]
}
