api_addr      = "https://{{HOSTNAME}}:8200"
cluster_addr  = "https://{{HOSTNAME}}:8201"
cluster_name  = "vault-cluster-{{CLUSTER_CONTEXT}}"
disable_mlock = true
ui            = true
listener "tcp" {
  address                            = "[::]:8200"
  tls_cert_file                      = "/vault/tls/bundle.pem"
  tls_key_file                       = "/vault/tls/key.pem"
  tls_disable_client_certs           = true
  tls_require_and_verify_client_cert = false
}
seal "shamir" {}
storage "raft" {
  path    = "/vault/file"
  node_id = "{{CLUSTER_CONTEXT}}-{{HOSTNAME}}"
  retry_join {
    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-1:8200"
    leader_ca_cert_file   = "/vault/tls/ca.pem"
    leader_tls_servername = "vault.server.{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
  }
  retry_join {
    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-2:8200"
    leader_ca_cert_file   = "/vault/tls/ca.pem"
    leader_tls_servername = "vault.server.{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
  }
  retry_join {
    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-3:8200"
    leader_ca_cert_file   = "/vault/tls/ca.pem"
    leader_tls_servername = "vault.server.{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
  }
}