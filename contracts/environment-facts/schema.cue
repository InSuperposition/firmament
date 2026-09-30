package environment_facts

import (
	"net"

	"github.com/insuperposition/firmament/contracts/layout"
)

// Types shared by every contract that carries an address or allocation.
#IPv4:      net.IPv4 & string
#CIDR:      net.IPCIDR & =~"^[0-9.]+/[0-9]+$"
#Port:      int & >=1 & <=65535
#MeshID:    int & >=1 & <=255
#MemoryMiB: int & >=256
#CPUs:      int & >=1
#DiskGiB:   int & >=1

// The sizes of one machine.
#Machine: {
	memory_mib!: #MemoryMiB
	cpus!:       #CPUs
	disk_gib!:   #DiskGiB
}

// The facts layer 3 supplies to one cluster's render. Each fact keeps its
// type here; the renderer turns them into strings for Flux substitution.
// pod_cidr feeds both the k0s configuration and Cilium (ipam.mode
// kubernetes). A package that needs a new fact adds it here in the same
// change.
#Facts: {
	cluster_name!:    layout.#Name
	mesh_cluster_id!: #MeshID
	pod_cidr!:        #CIDR
	service_cidr!:    #CIDR
	api_address!:     #IPv4
	api_port!:        #Port
	// Clusters admitted to the covenant's mesh; empty on a workload cluster.
	enrolled_clusters: [...layout.#Name]
	// Node-facing addresses of the covenant's services.
	covenant!: {
		openbao_address!: #IPv4
		zot_address!:     #IPv4
	}
	machine!: #Machine
}
