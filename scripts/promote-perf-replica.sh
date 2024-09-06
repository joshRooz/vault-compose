#!/usr/bin/env bash
set -oeu pipefail

# The scenarios where you would want to promote a PR secondary are very rare -
# e.g. "Primary is irretrievably corrupted. I have no primary backups. Promoting PR secondary is better than nothing."

usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the performance secondary cluster that will be promoted
    -p  context for the failed performance primary cluster that will be quarantined
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
echo "# initiating unplanned service disruption from - $id to $primary"
# all combinations of connecting to the primary cluster
./network-segmentation.sh -m deny -i "$primary" -s "$id" -c "$project"
./network-segmentation.sh -m deny -i "lb-$primary" -s "$id" -c "$project"
./network-segmentation.sh -m deny -i "lb-$primary" -s "lb-$id" -c "$project"
./network-segmentation.sh -m deny -i "$primary" -s "lb-$id" -c "$project"


# introduced above for simulation, but would be an intentional step in practice
echo "# quarantine the api/kmip traffic for the failed primary - $primary"


echo "# promoting performance secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
npp_port="$(get_port "${INSTANCES[0]}")"
export VAULT_SKIP_VERIFY=true
npp_token="$(get_admin_token "$id" "$project")"
VAULT_TOKEN=$npp_token VAULT_ADDR="https://localhost:$npp_port" \
vault write sys/replication/performance/secondary/promote primary_cluster_addr="https://lb-${id}.${domain}:8201" #force=true
# If there are multiple secondaries, they will need to be updated with the new primary address


echo "# recover, replace, etc. and restore the failed primary - $primary"


echo "# demote the failed primary - $primary"
FAILED=()
get_instances FAILED "$primary" "$project"
fp_port="$(get_port "${FAILED[0]}")"
fp_token="$(get_admin_token "$primary" "$project")"
VAULT_TOKEN=$fp_token VAULT_ADDR="https://localhost:$fp_port" \
  vault write -f sys/replication/performance/primary/demote


echo "# release the failed primary from quarantine - $primary"
./network-segmentation.sh -m allow -i "$primary" -s "$id" -c "$project"
./network-segmentation.sh -m allow -i "lb-$primary" -s "$id" -c "$project"
./network-segmentation.sh -m allow -i "lb-$primary" -s "lb-$id" -c "$project"
./network-segmentation.sh -m allow -i "$primary" -s "lb-$id" -c "$project"


echo "# generating secondary wrapped token - $id"
cnt=1 ; max=30
until wrapped_token="$(
  VAULT_ADDR="https://localhost:$npp_port" VAULT_TOKEN="$npp_token" \
  vault write -field=wrapping_token sys/replication/performance/primary/secondary-token \
  id="$primary" \
  ttl=5m
)"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done
VAULT_ADDR="https://localhost:$npp_port" VAULT_TOKEN=$npp_token vault token revoke -self


echo "# enable replication for the failed primary as a secondary - $primary"
cnt=1
until VAULT_TOKEN=$fp_token VAULT_ADDR=https://localhost:$fp_port \
  vault write sys/replication/performance/secondary/update-primary \
  token="$wrapped_token" \
  ca_file=/vault/tls/ca.pem \
  primary_api_addr="https://lb-${id}.${domain}"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done

# NOTEWORTHY: fp_token will be "lost" when update-primary reconciles the secondary
#VAULT_TOKEN=$fp_token vault token revoke -self

exit 0