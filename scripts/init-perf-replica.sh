#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  cluster context for the perf secondary
    -p  cluster context for the perf primary cluster
    -c  docker compose project name
    -d  docker compose network domain

    Example: replica 'b', primary 'a', compose project 'vault', and compose network 'example.internal'
    $0 -r b -p a -c vault -d example.internal" 1>&2
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
echo "# initializing perf secondary - $id"
instances=()
get_instances instances
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# perf primary - auth
pp_addr="https://localhost:$(docker inspect "${project}-${primary}-1" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
pp_token=$(VAULT_ADDR="$pp_addr" vault login -token-only -method=userpass username=admin password=admin)

# perf primary - check and enable replication
status="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault read -field=mode sys/replication/performance/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling performance replication"
  VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault write -f sys/replication/performance/primary/enable primary_cluster_addr="https://lb-${primary}.${domain}:8201"
fi

# perf primary - generate performance secondary token
echo "# generating performance secondary token - $id"
token="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" \
  vault write -field=wrapping_token sys/replication/performance/primary/secondary-token id="$id" ttl=5m)"
VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token"  vault token revoke -self

# activate performance replication
echo "# activate performance replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/performance/secondary/enable token="$token" ca_file=/vault/tls/ca.pem primary_api_addr="https://lb-${primary}.${domain}"

for i in "${instances[@]:1}"; do
  unseal_with_retry "$i" &
done
wait # local node not active but active cluster node not found

# configure autopilot
echo "# configure autopilot"
token="$(vault login -token-only -method=userpass username=admin password=admin)"
VAULT_TOKEN=$token vault operator raft autopilot set-config -cleanup-dead-servers=true -min-quorum=3 -dead-server-last-contact-threshold=2m # sys/storage/raft/autopilot
VAULT_TOKEN=$token vault token revoke -self