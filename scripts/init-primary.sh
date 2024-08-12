#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -p <primary_context> -c <compose_project>

    -p  cluster context for the primary
    -c  docker compose project name

    Example: primary 'a', and compose project 'vault'
    $0 -p a -c vault" 1>&2
}

# not checking for duplicates - we close our eyes and hope for the best in this demo
while getopts "p:c:" options ; do
  case "${options}" in
    p) id="${OPTARG}"  ;;
    c) project="${OPTARG}" ;;
    *) usage && exit 1 ;;
  esac
done

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
source "$SCRIPT_DIR/common.sh"


#---------------------------------------------------------------------
echo "# initialize and unseal primary vault cluster + non-voting standby's"
instances=()
get_instances instances
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
mkdir -p ../secrets
vault operator init -format=json -key-shares=1 -key-threshold=1 > ../secrets/init.json
vault operator unseal "$(jq -r .unseal_keys_b64[0] ../secrets/init.json)"

for i in "${instances[@]:1}" ; do
  unseal_with_retry "$i" &
done

export VAULT_TOKEN="$(jq -r .root_token ../secrets/init.json)"

echo "# configure autopilot"
vault operator raft autopilot set-config -cleanup-dead-servers=true -min-quorum=3 -dead-server-last-contact-threshold=2m # sys/storage/raft/autopilot

echo "# enable audit log with log_raw as ephemeral demo/test env"
vault audit enable file file_path=/proc/1/fd/1 low_raw=true

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

unset VAULT_TOKEN

wait
