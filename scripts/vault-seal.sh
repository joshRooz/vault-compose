#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -c <cluster_context> -p <compose_project> [-s]

    -s  default is to unseal the cluster. Provide this flag to seal the cluster.
    -c  cluster context
    -p  docker compose project name

    Example: cluster 'usca', and compose project 'vault'
    $0 -c usca -p vault" 1>&2
}

seal_action=false # unseal by default aka seal_action=false
while getopts "sp:c:" options ; do
  case "${options}" in
    s) seal_action=true ;;
    c) id="${OPTARG}"  ;;
    p) project="${OPTARG}" ;;
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
export VAULT_CACERT="../tls/root-ca/dev-root-ca.pem"
INSTANCES=()
get_instances INSTANCES "$id" "$project"

if $seal_action; then
  set +o errexit
  seal "$id" "$project"
  exit
fi

for i in "${INSTANCES[@]}" ; do
  unseal "$i"
done
