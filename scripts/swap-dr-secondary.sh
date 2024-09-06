#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -r <replica_context> -p <primary_context> -c <compose_project> -d <compose_domain>

    -r  context for the DR secondary cluster that will be promoted
    -p  context for the primary cluster that will be demoted
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
DEMOTE=()
get_instances DEMOTE "$primary" "$project"
ddp_port="$(get_port "${DEMOTE[0]}")"  # demoted dr primary (ddp)
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$ddp_port"
token="$(get_admin_token "$primary" "$project")"
export VAULT_TOKEN=$token
vault write -field=token auth/token/create/dr-operations ttl=8h > ../secrets/dr-ops-token
VAULT_TOKEN=$token vault token revoke -self
# end prerequisites


echo "# fetch the dr operations token"
export VAULT_TOKEN="$(cat ../secrets/dr-ops-token)"


echo "# quarantine api/kmip traffic for the primary that is being demoted - $primary"


echo "# demote the current primary - $primary"
vault write -f sys/replication/dr/primary/demote
ddp_addr=$VAULT_ADDR # stash demoted primary addr for later
unset VAULT_ADDR


echo "# promoting dr secondary - $id"
INSTANCES=()
get_instances INSTANCES "$id" "$project"
ndp_port="$(get_port "${INSTANCES[0]}")" # new dr primary (ndp)
export VAULT_ADDR="https://localhost:$ndp_port"
if ! vault write sys/replication/dr/secondary/promote \
  dr_operation_token="$VAULT_TOKEN" \
  primary_cluster_addr="https://lb-${id}.${domain}:8201"
then
  read -r -p "Failed to promote DR secondary - $id. Force promotion..."
  vault write sys/replication/dr/secondary/promote \
    dr_operation_token="$VAULT_TOKEN" \
    primary_cluster_addr="https://lb-${id}.${domain}:8201" \
    force=true
fi


echo "# generating secondary public key - $primary"
cnt=1 ; max=30
until pubkey="$(
  VAULT_ADDR="$ddp_addr" vault write \
  -field secondary_public_key \
  -f sys/replication/dr/secondary/generate-public-key
)"
do
  sleep $((cnt *= 2 ))
  if [[ $cnt -gt $max ]] ; then
    break
  fi
done


echo "# generating secondary token - $id"
cnt=1
until rep_token="$(
  vault write -field=token sys/replication/dr/primary/secondary-token \
  id="$primary" \
  ttl=5m \
  secondary_public_key="$pubkey"
)"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done


echo "# update replication for the demoted primary as a secondary - $primary"
cnt=1
until VAULT_ADDR="$ddp_addr" vault write sys/replication/dr/secondary/update-primary \
  dr_operation_token="$VAULT_TOKEN" \
  token="$rep_token"
do
  if [[ $cnt -gt $max ]] ; then
    break
  fi
  sleep $((cnt *= 2 ))
done
#VAULT_TOKEN=$token vault token revoke -self # batch token cannot be revoked

echo "# validate replication for any performance replicas is intact"

exit 0