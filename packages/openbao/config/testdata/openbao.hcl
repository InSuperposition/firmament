api_addr = "https://openbao.openbao.svc:8443"

listener "tcp" {
  address         = "127.0.0.1:8200"
  cluster_address = "[::]:8201"
  tls_disable     = true
}

listener "tcp" {
  address                         = "[::]:8443"
  tls_acme_ca_directory           = "http://127.0.0.1:8200/v1/pki/acme/directory"
  tls_acme_domains                = ["openbao.openbao.svc"]
  tls_acme_cache_path             = "/home/openbao/acme"
  tls_acme_disable_alpn_challenge = true
}

storage "raft" {
  path = "/openbao/data"
}

seal "static" {
  current_key_id = "seal-1"
  current_key    = "file:///openbao/seal/seal.key"
}

audit "file" "to-stdout" {
  options {
    file_path = "stdout"
  }
}

initialize "pki" {
  request "mount" {
    operation = "update"
    path      = "sys/mounts/pki"
    data = {
      type = "pki"
      config = { max_lease_ttl = "87600h" }
    }
  }
  request "tune" {
    operation = "update"
    path      = "sys/mounts/pki/tune"
    data = {
      allowed_response_headers = ["Last-Modified", "Location", "Replay-Nonce", "Link"]
      passthrough_request_headers = ["If-Modified-Since"]
    }
  }
  request "root" {
    operation = "update"
    path      = "pki/root/generate/internal"
    data = {
      common_name = "Firmament Root CA"
      key_type = "ec"
      key_bits = 256
      ttl = "87600h"
    }
  }
  request "cluster" {
    operation = "update"
    path      = "pki/config/cluster"
    data = {
      path = "http://127.0.0.1:8200/v1/pki"
      aia_path = "http://127.0.0.1:8200/v1/pki"
    }
  }
  request "acme" {
    operation = "update"
    path      = "pki/config/acme"
    data = {
      enabled = true
    }
  }
}

initialize "pki-roles" {
  request "role-cluster-leaf" {
    operation = "update"
    path      = "pki/roles/cluster-leaf"
    data = {
      key_type = "any"
      allowed_domains = ["cluster.local", "svc"]
      allow_subdomains = true
      require_cn = false
      max_ttl = "720h"
    }
  }
}

initialize "policies" {
  request "policy-pki-issue" {
    operation = "update"
    path      = "sys/policies/acl/pki-issue"
    data = {
      policy = "path \"pki/sign/cluster-leaf\" {\n  capabilities = [\"update\"]\n}\n"
    }
  }
  request "policy-snapshot" {
    operation = "update"
    path      = "sys/policies/acl/snapshot"
    data = {
      policy = "path \"sys/storage/raft/snapshot\" {\n  capabilities = [\"read\"]\n}\npath \"sys/storage/raft/snapshot-force\" {\n  capabilities = [\"update\"]\n}\n"
    }
  }
  request "policy-admin" {
    operation = "update"
    path      = "sys/policies/acl/admin"
    data = {
      policy = "path \"*\" {\n  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"]\n}\n"
    }
  }
}

initialize "kubernetes-auth" {
  request "enable" {
    operation = "update"
    path      = "sys/auth/kubernetes"
    data = {
      type = "kubernetes"
    }
  }
  request "config" {
    operation = "update"
    path      = "auth/kubernetes/config"
    data = {
      kubernetes_host = "https://kubernetes.default.svc"
    }
  }
  request "role-cert-manager" {
    operation = "update"
    path      = "auth/kubernetes/role/cert-manager"
    data = {
      bound_service_account_names = ["cert-manager"]
      bound_service_account_namespaces = ["cert-manager"]
      token_policies = ["pki-issue"]
      audience = "openbao"
    }
  }
  request "role-snapshot" {
    operation = "update"
    path      = "auth/kubernetes/role/snapshot"
    data = {
      bound_service_account_names = ["openbao"]
      bound_service_account_namespaces = ["openbao"]
      token_policies = ["snapshot"]
    }
  }
}

initialize "operator-auth" {
  request "enable" {
    operation = "update"
    path      = "sys/auth/cert"
    data = {
      type = "cert"
    }
  }
  request "operator" {
    operation = "update"
    path      = "auth/cert/certs/operator"
    data = {
      certificate = {
        eval_source = "file"
        eval_type   = "string"
        path        = "/openbao/operator-ca/operator-ca.pem"
      }
      allowed_common_names = ["operator"]
      token_policies = ["admin"]
      token_ttl = "1h"
    }
  }
}

