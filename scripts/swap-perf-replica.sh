#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the performance secondary cluster that will be promoted
    -p  context for the primary cluster that will be demoted
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
echo "# quarantine api/kmip traffic for the primary that is being demoted - $primary"


echo "# demote the current primary - $primary"
DEMOTE=()
get_instances DEMOTE "$primary" "$project"
port="$(get_port "${DEMOTE[0]}")"
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$port"
dp_token="$(get_admin_token "$primary" "$project")"
VAULT_TOKEN=$dp_token vault write -f sys/replication/performance/primary/demote
dp_addr=$VAULT_ADDR # stash demoted primary addr for later


echo "# promoting performance secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
port="$(get_port "${INSTANCES[0]}")"
export VAULT_ADDR="https://localhost:$port"
token="$(get_admin_token "$id" "$project")"
VAULT_TOKEN=$token vault write \
  sys/replication/performance/secondary/promote \
  primary_cluster_addr="https://lb-${id}.${domain}:8201" #force=true


echo "# generating secondary replication token - $id"
cnt=1 ; max=30
until wrapped_token="$(VAULT_TOKEN="$token" \
  vault write -field=wrapping_token sys/replication/performance/primary/secondary-token id="$primary" ttl=5m)"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done
VAULT_TOKEN=$token  vault token revoke -self


echo "# update replication for the demoted primary as a secondary - $primary"
cnt=1
until VAULT_ADDR=$dp_addr VAULT_TOKEN=$dp_token \
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
# NOTEWORTHY: dp_token will be "lost" when update-primary reconciles the secondary
#VAULT_TOKEN=$dp_token vault token revoke -self
# If there are multiple secondaries, they will need to be updated with the new primary address as well


echo "# release the demoted primary from api/kmip quarantine - $primary"

exit 0