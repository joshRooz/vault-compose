#!/usr/bin/env bash
set -oeu pipefail


usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the DR secondary cluster that will be promoted
    -p  context for the failed primary cluster that will be quarantined
    -c  docker compose project name
    -d  docker compose network domain

    Example: replica 'usil', primary 'usca', compose project 'vault', and compose network 'example.internal'
    $0 -r usil -p usca -c vault -d example.internal" 1>&2
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
echo "# prerequisite: stage and continously refresh a dr operation token"
FAILED=()
get_instances FAILED "$primary" "$project"
fdp_port="$(get_port "${FAILED[0]}")"  # failed dr primary (fdp)
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$fdp_port"
token="$(get_admin_token "$primary" "$project")"
export VAULT_TOKEN=$token
vault write -field=token auth/token/create/dr-operations ttl=8h > ../secrets/dr-ops-token
VAULT_TOKEN=$token vault token revoke -self


echo "# initiating unplanned service disruption from - $id to $primary"
# all combinations of connecting to the primary cluster
./network-segmentation.sh -m deny -i "$primary" -s "$id" -c "$project"
./network-segmentation.sh -m deny -i "lb-$primary" -s "$id" -c "$project"
./network-segmentation.sh -m deny -i "lb-$primary" -s "lb-$id" -c "$project"
./network-segmentation.sh -m deny -i "$primary" -s "lb-$id" -c "$project"


# introduced above for simulation, but would be an intentional step in practice
echo "# quarantine the api/kmip traffic for the failed primary - $primary"

echo "# fetch the dr operations token"
export VAULT_TOKEN="$(cat ../secrets/dr-ops-token)"


echo "# promoting dr secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
ndp_port="$(get_port "${INSTANCES[0]}")"  # ndp - new dr primary
VAULT_ADDR="https://localhost:$ndp_port" \
vault write sys/replication/dr/secondary/promote primary_cluster_addr="https://lb-${id}.${domain}:8201" #force=true
# If there are multiple secondaries, they will need to be updated with the new primary address


echo "# recover, replace, etc. and restore the failed primary - $primary"


echo "# demote the failed primary - $primary"
VAULT_ADDR="https://localhost:$fdp_port" \
  vault write -f sys/replication/dr/primary/demote


echo "# release the failed primary from quarantine - $primary"
./network-segmentation.sh -m allow -i "$primary" -s "$id" -c "$project"
./network-segmentation.sh -m allow -i "lb-$primary" -s "$id" -c "$project"
./network-segmentation.sh -m allow -i "lb-$primary" -s "lb-$id" -c "$project"
./network-segmentation.sh -m allow -i "$primary" -s "lb-$id" -c "$project"


echo "# generating secondary public key - $primary"
cnt=1 ; max=30
until pubkey="$(
  VAULT_ADDR="https://localhost:$fdp_port" vault write \
  -field secondary_public_key \
  -f sys/replication/dr/secondary/generate-public-key
)"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done


echo "# generating secondary wrapped token - $id"
cnt=1 ; max=30
until wrapped_token="$(
  VAULT_ADDR="https://localhost:$ndp_port" vault write \
  -field=wrapping_token sys/replication/dr/primary/secondary-token \
  id="$primary" \
  ttl=5m
)"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done


echo "# enable replication for the failed primary as a secondary - $primary"
cnt=1
until VAULT_ADDR=https://localhost:$fdp_port \
  vault write sys/replication/dr/secondary/update-primary \
  token="$wrapped_token" \
  ca_file=/vault/tls/ca.pem \
  primary_api_addr="https://lb-${id}.${domain}"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done

exit 0