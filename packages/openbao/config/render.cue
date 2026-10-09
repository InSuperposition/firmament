package openbaoconfig

import (
	"strconv"
	"strings"
)

// Where the chart values mount what the config reads, and the ports it
// listens on. The cluster's values file must mount the seal key Secret and
// the operator CA ConfigMap at these paths and the data volume at #DataPath.
#SealKeyPath:             "/openbao/seal/seal.key"
#OperatorCAPath:          "/openbao/operator-ca/operator-ca.pem"
#DataPath:                "/openbao/data"
#SealSecretName:          "openbao-static-seal"
#OperatorCAConfigMapName: "openbao-operator-ca"
#PlainListenerPort:       8200
#TLSListenerPort:         8443
#ClusterListenerPort:     8201

// #Render turns the data sections into the server config the chart installs
// as server.ha.raft.config. namespace is the one the binding places OpenBao
// in: the listener's certificate is for the Service name inside it.
//
// HCL strings are written with strconv.Quote, whose escapes HCL reads the
// same way for the ASCII this config holds. Objects nest one level deep
// only: the HCL parser OpenBao uses refuses a list inside a nested object.
#Render: {
	config:    #Config
	namespace: #Name

	// The chart values that must agree with the config: the volumes it
	// reads, the port it serves on and the name its certificate is for.
	// The cluster's values file sets everything else.
	values: server: {
		// The chart exposes 8200 and runs its own probes against the plain
		// loopback listener with exec; clients reach the TLS listener.
		extraPorts: [{containerPort: #TLSListenerPort, name: "https"}]
		service: targetPort: #TLSListenerPort
		// The ACME client reaches the PKI's challenge at the Service name,
		// which resolves to the pod's own loopback (C88).
		hostAliases: [{ip: "127.0.0.1", hostnames: [_domain]}]
		ha: raft: "config": hcl
		volumes: [
			{name: "data", hostPath: {path: config.storage.host_path, type: "DirectoryOrCreate"}},
			{name: "seal", secret: {secretName: #SealSecretName}},
			{name: "operator-ca", configMap: {name: #OperatorCAConfigMapName}},
		]
		volumeMounts: [
			{name: "data", mountPath: #DataPath},
			{name: "seal", mountPath: "/openbao/seal", readOnly: true},
			{name: "operator-ca", mountPath: "/openbao/operator-ca", readOnly: true},
		]
		// A hostPath folder is created owned by root and fsGroup does not
		// apply to it; the server runs as 100:1000.
		extraInitContainers: [{
			name:  "data-owner"
			image: config.storage.init_image
			command: ["chown", "-R", "100:1000", #DataPath]
			securityContext: runAsUser: 0
			volumeMounts: [{name: "data", mountPath: #DataPath}]
		}]
	}

	// A role or the operator naming a policy that is not declared is an
	// error that names the policy.
	for roleName, role in config.kubernetes.roles for policy in role.policies {
		policyDefined: (roleName): (policy): config.policies[policy]
	}
	for policy in config.operator.policies {
		operatorPolicyDefined: (policy): config.policies[policy]
	}

	hcl: strings.Join([_server + "\n", _pki.out, _roles.out, _policies.out, _kubernetes.out, _operator.out], "\n")

	_domain: "openbao.\(namespace).svc"
	_plain:  "http://127.0.0.1:\(#PlainListenerPort)/v1/pki"

	_server: """
		disable_mlock = true
		api_addr      = \(strconv.Quote("https://\(_domain):\(#TLSListenerPort)"))

		listener "tcp" {
		  address         = "127.0.0.1:\(#PlainListenerPort)"
		  cluster_address = "[::]:\(#ClusterListenerPort)"
		  tls_disable     = true
		}

		listener "tcp" {
		  address                         = "[::]:\(#TLSListenerPort)"
		  tls_acme_ca_directory           = "\(_plain)/acme/directory"
		  tls_acme_domains                = [\(strconv.Quote(_domain))]
		  tls_acme_cache_path             = \(strconv.Quote("\(#DataPath)/acme"))
		  tls_acme_disable_alpn_challenge = true
		}

		storage "raft" {
		  path = \(strconv.Quote(#DataPath))
		}

		seal "static" {
		  current_key_id = "seal-1"
		  current_key    = \(strconv.Quote("file://\(#SealKeyPath)"))
		}

		audit "file" "to-stdout" {
		  options {
		    file_path = "stdout"
		  }
		}
		"""

	_rootBits: [if config.pki.root.key_type == "ec" {256}, 4096][0]

	_pki: #Initialize & {
		name: "pki"
		requests: [
			{name: "mount", path: "sys/mounts/pki", data: [
				"type = \"pki\"",
				"config = { max_lease_ttl = \(strconv.Quote(config.pki.root.ttl)) }",
			]},
			// The mount returns these headers only when it allows them, and
			// the ACME client refuses a response without Replay-Nonce.
			{name: "tune", path: "sys/mounts/pki/tune", data: [
				"allowed_response_headers = [\"Last-Modified\", \"Location\", \"Replay-Nonce\", \"Link\"]",
				"passthrough_request_headers = [\"If-Modified-Since\"]",
			]},
			{name: "root", path: "pki/root/generate/internal", data: [
				"common_name = \(strconv.Quote(config.pki.root.common_name))",
				"key_type = \(strconv.Quote(config.pki.root.key_type))",
				"key_bits = \(_rootBits)",
				"ttl = \(strconv.Quote(config.pki.root.ttl))",
			]},
			{name: "cluster", path: "pki/config/cluster", data: [
				"path = \(strconv.Quote(_plain))",
				"aia_path = \(strconv.Quote(_plain))",
			]},
			{name: "acme", path: "pki/config/acme", data: ["enabled = true"]},
		]
	}

	_roles: #Initialize & {
		name: "pki-roles"
		requests: [
			for roleName, role in config.pki.roles {
				name: "role-\(roleName)"
				path: "pki/roles/\(roleName)"
				data: [
					"key_type = \(strconv.Quote(role.key_type))",
					"allowed_domains = \((#List & {in: role.allowed_domains}).out)",
					"allow_subdomains = \(role.allow_subdomains)",
					"require_cn = \(role.require_cn)",
					"max_ttl = \(strconv.Quote(role.max_ttl))",
				]
			},
		]
	}

	_policies: #Initialize & {
		name: "policies"
		requests: [
			for policyName, rules in config.policies {
				name: "policy-\(policyName)"
				path: "sys/policies/acl/\(policyName)"
				data: [
					"policy = \(strconv.Quote(strings.Join([for rule in rules {(#PolicyRule & {"rule": rule}).out}], "")))",
				]
			},
		]
	}

	_kubernetes: #Initialize & {
		name: "kubernetes-auth"
		requests: [
			{name: "enable", path: "sys/auth/kubernetes", data: ["type = \"kubernetes\""]},
			{name: "config", path: "auth/kubernetes/config", data: ["kubernetes_host = \(strconv.Quote(config.kubernetes.host))"]},
			for roleName, role in config.kubernetes.roles {
				name: "role-\(roleName)"
				path: "auth/kubernetes/role/\(roleName)"
				data: [
					"bound_service_account_names = \((#List & {in: [role.service_account]}).out)",
					"bound_service_account_namespaces = \((#List & {in: [role.namespace]}).out)",
					"token_policies = \((#List & {in: role.policies}).out)",
					"audience = \(strconv.Quote(role.audience))",
				]
			},
		]
	}

	_operator: #Initialize & {
		name: "operator-auth"
		requests: [
			{name: "enable", path: "sys/auth/cert", data: ["type = \"cert\""]},
			{name: "operator", path: "auth/cert/certs/operator", data: [
				// The CA is public; the file is mounted from the ConfigMap the
				// seed task creates from private state.
				"certificate = {\n        eval_source = \"file\"\n        eval_type   = \"string\"\n        path        = \(strconv.Quote(#OperatorCAPath))\n      }",
				"allowed_common_names = \((#List & {in: [config.operator.common_name]}).out)",
				"token_policies = \((#List & {in: config.operator.policies}).out)",
				"token_ttl = \(strconv.Quote(config.operator.ttl))",
			]},
		]
	}
}

// A quoted HCL list of strings.
#List: {
	in: [...string]
	out: "[" + strings.Join([for s in in {strconv.Quote(s)}], ", ") + "]"
}

// One ACL rule as the text of a policy.
#PolicyRule: {
	rule: {path: string, capabilities: [...string]}
	out: "path \(strconv.Quote(rule.path)) {\n  capabilities = \((#List & {in: rule.capabilities}).out)\n}\n"
}

// An initialize block: its requests run in order, each an update.
#Initialize: {
	name: string
	requests: [...{name: string, path: string, data: [...string]}]
	out: string
	out: strings.Join([
		"initialize \(strconv.Quote(name)) {",
		for r in requests {
			strings.Join([
				"  request \(strconv.Quote(r.name)) {",
				"    operation = \"update\"",
				"    path      = \(strconv.Quote(r.path))",
				"    data = {",
				for line in r.data {"      \(line)"},
				"    }",
				"  }",
			], "\n")
		},
		"}",
		"",
	], "\n")
}
