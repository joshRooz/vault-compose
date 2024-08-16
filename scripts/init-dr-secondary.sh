#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <secondary_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the dr secondary cluster
    -p  context for the dr primary cluster
    -c  docker compose project name
    -d  docker compose network domain

    Example: dr 'usil', primary 'usca', compose project 'vault', and compose network 'example.internal'
    $0 -r usil -p usca -p vault -d example.internal" 1>&2
}

while getopts "r:p:c:d:" options ; do
  case "${options}" in
    r) id="${OPTARG}" ;;
    p) primary="${OPTARG}" ;;
    c) project="${OPTARG}" ;;
    d) domain="${OPTARG}" ;;
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
echo "# initializing dr secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
port="$(get_port "${INSTANCES[0]}")"

export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$port"

vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# dr secondary - generate public key used to encrypt the token
pubkey="$(VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write -f -field=secondary_public_key \
  /sys/replication/dr/secondary/generate-public-key
)"

# dr primary - auth
dp_port="$(get_port "${project}-${primary}-1")"
dp_addr="https://localhost:$dp_port"
dp_token=$(get_admin_token "$primary" "$project")

# dr primary - check and enable replication
status="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault read -field=mode sys/replication/dr/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling dr replication"
  VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault write -f \
  sys/replication/dr/primary/enable \
  primary_cluster_addr="https://lb-${primary}.${domain}:8201"
fi

echo "# generating dr secondary replication token - $id"
rep_token="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" \
  vault write -field=token sys/replication/dr/primary/secondary-token secondary_public_key="$pubkey" id="$id" ttl=2m)"
VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token"  vault token revoke -self

echo "# activate dr replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/dr/secondary/enable \
  token="$rep_token" \
  ca_file=/vault/tls/ca.pem

# unseal remaining instances now that replication is active
for i in "${INSTANCES[@]:1}"; do
  unseal "$i" &
done
wait