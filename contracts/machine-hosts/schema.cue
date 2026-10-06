package machinehosts

import "net"

// The machine-hosts contract: everything the Kubernetes root needs to
// reach a machine. Closed: a field not declared here is refused.
// contracts:lint checks the sample against #Contract; roots/kubernetes-k0s
// checks the file it reads against the same fields.
#Contract: #MachineHosts

#Name: =~"^[a-z][a-z0-9-]*$"

// One known_hosts line without the host: <type> <base64 key>.
#HostKey: =~"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+$"

#MachineHosts: close({
	name!:       #Name
	dns_name!:   string & !=""
	ip_address!: net.IP
	ssh!: close({
		address!:  string & !=""
		port!:     int & >=1 & <=65535
		user!:     string & !=""
		key_path!: string & !=""
		// Optional until machines-orbstack writes it and makes it required.
		host_keys?: [...#HostKey]
	})
})
