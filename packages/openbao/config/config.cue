package openbaoconfig

// The data sections of OpenBao on one cluster: clusters/<cluster>/openbao.yaml.
// Closed: a field not declared here is refused, naming it. Every decision
// that a wrong value would make permanent is required, not defaulted: a
// failed self-init is sticky, and the only repair is to wipe the storage.
#Config: close({
	pki!: close({
		root!: close({
			common_name!: string & !=""
			key_type!:    "ec" | "rsa"
			ttl!:         #Duration
		})
		// The roles that issue certificates. key_type must be one the clients
		// request: cert-manager asks for RSA unless a Certificate says
		// otherwise, so a role that names ec refuses them, and "any" accepts
		// both. require_cn is a decision, never a default.
		roles!: {[#Name]: close({
			key_type!: #KeyType
			allowed_domains!: [string & !="", ...]
			allow_subdomains!: bool
			require_cn!:       bool
			max_ttl!:          #Duration
		})
		}
	})

	// Where the data directory lives on the machine, and the image of the
	// init container that gives it to the user OpenBao runs as. The init
	// image should be the chart's appVersion; a different tag only costs a
	// second image pull.
	storage!: close({
		host_path!:  =~"^/[A-Za-z0-9._/-]+$"
		init_image!: string & !=""
	})

	// ACL policies by name; the Kubernetes roles and the operator name them.
	policies!: {[#Name]: [...close({
		path!: string & !=""
		capabilities!: [#Capability, ...]
	})] & [_, ...]}

	kubernetes!: close({
		host!: string & !=""
		roles!: {[#Name]: close({
			service_account!: #Name
			namespace!:       #Name
			policies!: [#Name, ...]
			// Checked against the token's audience when set; a role for the pod's
			// own default token leaves it out.
			audience?: string & !=""
		})
		}
	})

	// The certificate login of the operator (C89): any client certificate
	// signed by the operator CA in private state whose common name matches.
	operator!: close({
		common_name!: string & !=""
		policies!: [#Name, ...]
		ttl!: #Duration
	})
})

#Name:       =~"^[a-z][a-z0-9-]*$"
#Duration:   =~"^[0-9]+(s|m|h)$"
#KeyType:    "rsa" | "ec" | "ed25519" | "any"
#Capability: "create" | "read" | "update" | "delete" | "list" | "sudo"
