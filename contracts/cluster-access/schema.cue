package clusteraccess

// The cluster-access contract: where the kubeconfig is and the runtime
// values Flux substitutes into every package. Closed: a field not declared
// here is refused. Every runtime value is a string because Flux
// substitution is plain text replacement.
#Contract: #ClusterAccess

#ClusterAccess: close({
	kubeconfig_path!: string & !=""
	runtime_info!: close({
		api_address!:              string
		api_port!:                 string
		kube_proxy_replacement!:   string
		cilium_datapath_mode!:     string
		cilium_operator_replicas!: string
		environment!:              string
		cluster!:                  string
		git_branch!:               string
	})
})
