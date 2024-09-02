#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -p <primary_context> -c <compose_project>

    -p  context for the primary cluster
    -c  docker compose project name

    Example: primary 'usca', and compose project 'vault'
    $0 -p usca -c vault" 1>&2
}

while getopts "p:c:" options ; do
  case "${options}" in
    p) id="${OPTARG}"  ;;
    c) project="${OPTARG}" ;;
    *) usage && exit 1 ;;
  esac
done

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
for f in "$SCRIPT_DIR"/lib/*.sh ; do
  # shellcheck source=/dev/null
  source "$f"
done


#---------------------------------------------------------------------
echo "# initialize and unseal primary vault cluster"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
port="$(get_port "${INSTANCES[0]}")"

export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$port"

mkdir -p ../secrets
vault operator init -format=json -key-shares=1 -key-threshold=1 > ../secrets/init.json

vault operator unseal "$(jq -r .unseal_keys_b64[0] ../secrets/init.json)"
export VAULT_TOKEN="$(jq -r .root_token ../secrets/init.json)"

for i in "${INSTANCES[@]:1}" ; do
  unseal "$i" &
done


echo "# configure autopilot"
vault operator raft autopilot set-config \
  -cleanup-dead-servers=true -min-quorum=3 -dead-server-last-contact-threshold=2m

# we would want to separate log streams in practice, but this makes for an
# easy path into promtail -> loki -> grafana
echo "# enable audit log with log_raw as ephemeral demo/test env"
vault audit enable file file_path=/proc/1/fd/1 low_raw=true

echo "# setup userpass for admin auth"
vault auth enable userpass
vault write -f auth/userpass/users/admin password=admin policies=global-wildcard

cat - <<EOF | vault policy write global-wildcard -
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF

cat - <<EOF | vault policy write dr-operations -
path "sys/replication/dr/secondary/promote" { capabilities = [ "update" ] }
path "sys/replication/dr/secondary/update-primary" { capabilities = [ "update" ] }
path "sys/storage/raft/autopilot/state" { capabilities = [ "update" , "read" ] }
# additional permissions to update a demoted, or recover a failed, primary
path "sys/replication/dr/primary/demote" { capabilities = [ "create", "update" ] }
path "sys/replication/dr/secondary/generate-public-key" { capabilities = [ "create", "update" ] }
path "sys/replication/dr/primary/secondary-token" { capabilities = [ "create", "update", "sudo" ] }
EOF
vault write auth/token/roles/dr-operations \
  allowed_policies=dr-operations \
  orphan=true \
  renewable=false \
  token_type=batch

unset VAULT_TOKEN

wait
