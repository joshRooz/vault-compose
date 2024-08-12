api_addr          = "https://{{HOSTNAME}}:8200"
cluster_addr      = "https://{{HOSTNAME}}:8201"
cluster_name      = "vault-cluster-{{CLUSTER_CONTEXT}}"
default_lease_ttl = "1h"
disable_mlock     = true
ui                = true
listener "tcp" {
  address                            = "[::]:8200"
  tls_cert_file                      = "/vault/tls/bundle.pem"
  tls_key_file                       = "/vault/tls/key.pem"
  tls_disable_client_certs           = true
  tls_require_and_verify_client_cert = false

  proxy_protocol_behavior         = "allow_authorized"
  proxy_protocol_authorized_addrs = "{{PROXY_ADDR}}"
  telemetry {
    unauthenticated_metrics_access = true
  }
}
replication {
  allow_forwarding_via_token = "new_token"
}
seal "shamir" {}
storage "raft" {
  path                      = "/vault/file"
  node_id                   = "{{CLUSTER_CONTEXT}}-{{HOSTNAME}}"
  autopilot_redundancy_zone = "{{AZ}}"
  autopilot_upgrade_version = "{{CLUSTER_VERSION}}"
  retry_join {
    leader_api_addr       = "https://{{CLUSTER_CONTEXT}}:8200"
    leader_ca_cert_file   = "/vault/tls/ca.pem"
    leader_tls_servername = "{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
  }
}
telemetry {
  disable_hostname          = true
  enable_hostname_label     = true
  prometheus_retention_time = "2m"
}
