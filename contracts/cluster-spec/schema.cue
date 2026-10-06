package clusterspec

// The cluster.yaml format. Closed: a cluster has no role, because its
// roles are what its packages provide (C62). contracts:lint checks the
// sample against #Contract.
#Contract: #Cluster

#Cluster: close({
	// Names the folder clusters/<name>/ the file sits in.
	name!: =~"^[a-z][a-z0-9-]*$"
})
