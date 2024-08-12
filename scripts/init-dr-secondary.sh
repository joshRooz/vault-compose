#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <secondary_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  cluster context for the dr secondary cluster
    -p  container name for the primary cluster
    -c  docker compose project name
    -d  docker compose network domain

    Example: dr 'c', primary 'a', compose project 'vault', and compose network 'example.internal'
    $0 -r c -p a -p vault -d example.internal" 1>&2
}

# not checking for duplicates - we close our eyes and hope for the best in this demo
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
source "$SCRIPT_DIR/common.sh"


#---------------------------------------------------------------------
echo "# initializing dr secondary - $id"
instances=()
get_instances instances
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# dr secondary - generate public key used to encrypt the token
pubkey="$(VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write -f -field=secondary_public_key /sys/replication/dr/secondary/generate-public-key)"

# dr primary - auth
dp_addr="https://localhost:$(docker inspect "${project}-${primary}-1" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
dp_token=$(VAULT_ADDR="$dp_addr" vault login -token-only -method=userpass username=admin password=admin)

# dr primary - check and enable replication
status="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault read -field=mode sys/replication/dr/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling dr replication"
  VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault write -f sys/replication/dr/primary/enable primary_cluster_addr="https://lb-${primary}.${domain}:8201"
fi

# dr primary - generate dr secondary token
echo "# generating dr secondary token - $id"
token="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" \
  vault write -field=token sys/replication/dr/primary/secondary-token secondary_public_key="$pubkey" id="$id" ttl=2m)"
VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token"  vault token revoke -self

# dr secondary - activate dr replication
echo "# activate dr replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/dr/secondary/enable token="$token" ca_file=/vault/tls/ca.pem primary_api_addr="https://lb-${primary}.${domain}"

for i in "${instances[@]:1}"; do
  unseal_with_retry "$i" &
done
wait