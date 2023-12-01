#!/usr/bin/env bash
set -oeu pipefail

#---------------------------------------------------------------------
# initialize and unseal primary vault cluster + non-voting standby's
echo "# initialize and unseal primary vault cluster + non-voting standby's"
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect vault-usca-1 | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > secrets/init.json
vault operator unseal "$(jq -r .unseal_keys_b64[0] secrets/init.json)"

sleep 5 #? specific endpoint to gaurantee no transient failure due to #too-soon
for i in vault-usca-2 vault-usca-3 vault-uscaps-1 vault-uscaps-2 vault-uscaps-3 ; do
  VAULT_ADDR="https://localhost:$(docker inspect $i | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"  vault operator unseal "$(jq -r .unseal_keys_b64[0] secrets/init.json)"
done

# enable audit log with log_raw as ephemeral demo/test env
echo "# enable audit log with log_raw as ephemeral demo/test env"
export VAULT_TOKEN="$(jq -r .root_token secrets/init.json)"
vault audit enable file file_path=/var/log/vault_audit.log log_raw=true

# setup auth for perf secondary
vault auth enable userpass
vault write -f auth/userpass/users/foo password=bar policies=global-wildcard

vault policy write global-wildcard - <<EOF
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF

vault policy write dr-ops - <<EOF
path "sys/replication/dr/secondary/promote" { capabilities = [ "update" ] }
path "sys/replication/dr/secondary/update-primary" { capabilities = [ "update" ] }
path "sys/storage/raft/autopilot/state" { capabilities = [ "update" , "read" ] }
EOF
vault write auth/token/roles/dr-ops allowed_policies=dr-ops orphan=true renewable=false token_type=batch
drops_token="$(vault token create -field=token -role=dr-ops -ttl=5m)"

# prep for perf secondary - new york
echo "# prep for perf secondary"
vault read sys/replication/performance/status
vault write -f sys/replication/performance/primary/enable
pr_token="$(vault write sys/replication/performance/primary/secondary-token -format=json id=usny ttl=5m | jq -r .wrap_info.token)"

# prep for dr secondary - illnois
echo "# prep for dr secondary"
vault read sys/replication/dr/status
vault write -f sys/replication/dr/primary/enable
dr_token="$(vault write sys/replication/dr/primary/secondary-token -format=json id=usil ttl=10m | jq -r .wrap_info.token)"
unset VAULT_TOKEN


#---------------------------------------------------------------------
# onto perf secondary - new york
echo "# onto perf secondary"
export VAULT_ADDR="https://localhost:$(docker inspect vault-usny-1 | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > /tmp/usny.json
vault operator unseal "$(jq -r .unseal_keys_b64[0] /tmp/usny.json)"

# activate performance replication
echo "# activate performance replication"
VAULT_TOKEN="$(jq -r .root_token /tmp/usny.json)" vault write sys/replication/performance/secondary/enable token="$pr_token" ca_file=/vault/tls/ca.pem

#vault_token=$(vault login -token-only -method=userpass username=foo password=bar)
sleep 5 #? specific endpoint to gaurantee no transient failure due to #too-soon
for i in vault-usny-2 vault-usny-3 ; do
  VAULT_ADDR="https://localhost:$(docker inspect $i | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"  vault operator unseal "$(jq -r .unseal_keys_b64[0] secrets/init.json)"
done

# prep for dr secondary [off perf secondary] - ustx
export VAULT_TOKEN="$(vault login -token-only -method=userpass username=foo password=bar)"
echo "# prep for dr secondary"
vault read sys/replication/dr/status
vault write -f sys/replication/dr/primary/enable
prdr_token="$(vault write sys/replication/dr/primary/secondary-token -format=json id=ustx ttl=10m | jq -r .wrap_info.token)"
prdrops_token="$(vault token create -field=token -role=dr-ops -ttl=5m)"

# prep for testing recovery scenarios - use names that won't change when we blow away containers
sleep 2
vault write sys/replication/performance/secondary/update-primary update_primary_addrs=vault-usca-1:8201,vault-usca-2:8201,vault-usca-3:8201
unset VAULT_TOKEN


#---------------------------------------------------------------------
# onto dr secondary - usil
echo "# onto perf primary dr secondary"
export VAULT_ADDR="https://localhost:$(docker inspect vault-usil-1 | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > /tmp/usil.json
vault operator unseal "$(jq -r .unseal_keys_b64[0] /tmp/usil.json)"

# activate dr replication
echo "# activate dr replication"
VAULT_TOKEN="$(jq -r .root_token /tmp/usil.json)" vault write sys/replication/dr/secondary/enable token="$dr_token"  ca_file=/vault/tls/ca.pem

sleep 5 #? specific endpoint to gaurantee no transient failure due to #too-soon
for i in vault-usil-2 vault-usil-3 ; do
  VAULT_ADDR="https://localhost:$(docker inspect $i | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"  vault operator unseal "$(jq -r .unseal_keys_b64[0] secrets/init.json)"
done

# prep for testing recovery scenarios - use names that won't change when we blow away containers
VAULT_TOKEN="$drops_token" vault write sys/replication/dr/secondary/update-primary update_primary_addrs=vault-usca-1:8201,vault-usca-2:8201,vault-usca-3:8201

#---------------------------------------------------------------------
# onto dr Secondary [off Perf Secondary]
echo "# onto perf replica dr secondary"
export VAULT_ADDR="https://localhost:$(docker inspect vault-ustx-1 | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
ustx="$(vault operator init -format=json -key-shares=1 -key-threshold=1)"
vault operator unseal "$(jq -r .unseal_keys_b64[0] <<<"$ustx")"

# activate dr replication
echo "# activate dr replication"
VAULT_TOKEN="$(jq -r .root_token <<<"$ustx")" vault write sys/replication/dr/secondary/enable token="$prdr_token"  ca_file=/vault/tls/ca.pem

# prep for testing recovery scenarios - use names that won't change when we blow away containers
sleep 2
VAULT_TOKEN="$prdrops_token" vault write sys/replication/dr/secondary/update-primary update_primary_addrs=vault-usny-1:8201,vault-usny-2:8201,vault-usny-3:8201
