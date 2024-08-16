#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the performance secondary cluster
    -p  context for the performance primary cluster
    -c  docker compose project name
    -d  docker compose network domain

    Example: replica 'usny', primary 'usca', compose project 'vault', and compose network 'example.internal'
    $0 -r usny -p usca -c vault -d example.internal" 1>&2
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
echo "# initializing performance secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
port="$(get_port "${INSTANCES[0]}")"

export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$port"

vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# perf primary - auth
pp_port="$(get_port "${project}-${primary}-1")"
pp_addr="https://localhost:$pp_port"
pp_token="$(get_admin_token "$primary" "$project")"

# perf primary - check and enable replication
status="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault read -field=mode sys/replication/performance/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling performance replication"
  VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault write -f \
    sys/replication/performance/primary/enable \
    primary_cluster_addr="https://lb-${primary}.${domain}:8201"
fi

echo "# generating performance secondary replication token - $id"
rep_token="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" \
  vault write -field=wrapping_token sys/replication/performance/primary/secondary-token id="$id" ttl=5m)"
VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token"  vault token revoke -self

# I believe a raft log commit race condition is experienced here.
# manifests as a tls trust issue for the container name.
#eat
sleep 5
#pray... if you're here eat more, sleep more, and pray more. or, pr a fix :)

echo "# activate performance replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/performance/secondary/enable \
  token="$rep_token" \
  ca_file=/vault/tls/ca.pem \
  primary_api_addr="https://lb-${primary}.${domain}"

# unseal remaining instances now that replication is active
for i in "${INSTANCES[@]:1}"; do
  unseal "$i" &
done
wait


# configure autopilot
echo "# configure autopilot"
token="$(get_admin_token "$id" "$project")"
VAULT_TOKEN=$token vault operator raft autopilot set-config \
  -cleanup-dead-servers=true -min-quorum=3 -dead-server-last-contact-threshold=2m
VAULT_TOKEN=$token vault token revoke -self