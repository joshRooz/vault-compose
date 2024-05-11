#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -i <instance> -r <secondary_id> -p <primary_instance>

    -i  container name(s) for the dr secondary cluster
    -r  dr secondary id
    -p  container name for the primary cluster

    Example: 3 secondary cluster instances, cluster id, and a primary instance
    $0 -i vaultb01 -i vaultb02 -i vaultb03 -r foo -p vaulta01" 1>&2
}

# not checking for duplicates - we close our eyes and hope for the best in this demo
while getopts "i:r:p:" options ; do
  case "${options}" in
    i) instances+=("${OPTARG}") ;;
    r) id="${OPTARG}" ;;
    p) primary="${OPTARG}" ;;
    *) usage && exit 1 ;;
  esac
done

#---------------------------------------------------------------------
echo "# initializing dr secondary - $id"
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# dr primary - auth
dp_addr="https://localhost:$(docker inspect "${primary}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
dp_token=$(VAULT_ADDR="$dp_addr" vault login -token-only -method=userpass username=admin password=admin ttl=5m)

# dr primary - check and enable replication
status="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault read -field=mode sys/replication/dr/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling dr replication"
  VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" vault write -f sys/replication/dr/primary/enable
fi

# dr primary - generate dr secondary token
echo "# generating dr secondary token - $id"
token="$(VAULT_ADDR="$dp_addr" VAULT_TOKEN="$dp_token" \
  vault write -field=wrapping_token sys/replication/dr/primary/secondary-token id="$id" ttl=5m)"

# activate dr replication
echo "# activate dr replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/dr/secondary/enable token="$token" ca_file=/vault/tls/ca.pem
