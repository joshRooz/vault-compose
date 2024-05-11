#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -i <instance>

    -i  container name(s) for the cluster

    Example: 1 cluster instances
    $0 -i vaulta01 -i vaulta02 -i vaulta03" 1>&2
}

# not checking for duplicates - we close our eyes and hope for the best in this demo
while getopts "i:" options ; do
  case "${options}" in
    i) instances+=("${OPTARG}") ;;
    *) usage && exit 1 ;;
  esac
done


# initialize and unseal primary vault cluster + non-voting standby's
echo "# initialize and unseal primary vault cluster + non-voting standby's"
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > ../secrets/init.json
vault operator unseal "$(jq -r .unseal_keys_b64[0] ../secrets/init.json)"

sleep 5 #? specific endpoint to gaurantee no transient failure due to #too-soon
for i in "${instances[@]:1}" ; do
  VAULT_ADDR="https://localhost:$(docker inspect $i | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')" \
    vault operator unseal "$(jq -r .unseal_keys_b64[0] ../secrets/init.json)" >/dev/null &
done

export VAULT_TOKEN="$(jq -r .root_token ../secrets/init.json)"

# enable audit log with log_raw as ephemeral demo/test env
echo "# enable audit log with log_raw as ephemeral demo/test env"
vault audit enable file file_path=/var/log/vault_audit.log log_raw=true

# setup admin auth
vault auth enable userpass
vault write -f auth/userpass/users/admin password=admin policies=global-wildcard

vault policy write global-wildcard - <<EOF
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF

vault policy write dr-ops - <<EOF
path "sys/replication/dr/secondary/promote" { capabilities = [ "update" ] }
path "sys/replication/dr/secondary/update-primary" { capabilities = [ "update" ] }
path "sys/storage/raft/autopilot/state" { capabilities = [ "update" , "read" ] }
EOF

unset tokens
unset VAULT_TOKEN

wait