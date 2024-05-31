#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -i <instance> -r <replica_id> -p <primary_instance>

    -i  container name(s) for the perf secondary cluster
    -r  performance secondary id
    -p  container name for the perf primary cluster

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
echo "# initializing perf secondary - $id"
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR="https://localhost:$(docker inspect "${instances[0]}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
vault operator init -format=json -key-shares=1 -key-threshold=1 > "/tmp/$id.json"
vault operator unseal "$(jq -r .unseal_keys_b64[0] "/tmp/$id.json")"

# perf primary - auth
pp_addr="https://localhost:$(docker inspect "${primary}" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
pp_token=$(VAULT_ADDR="$pp_addr" vault login -token-only -method=userpass username=admin password=admin ttl=5m)

# perf primary - check and enable replication
status="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault read -field=mode sys/replication/performance/status)"
if [[ "$status" == "disabled" ]] ; then
  echo "# enabling performance replication"
  VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" vault write -f sys/replication/performance/primary/enable
fi

# perf primary - generate performance secondary token
echo "# generating performance secondary token - $id"
token="$(VAULT_ADDR="$pp_addr" VAULT_TOKEN="$pp_token" \
  vault write -field=wrapping_token sys/replication/performance/primary/secondary-token id="$id" ttl=5m)"

# activate performance replication
echo "# activate performance replication - $id"
VAULT_TOKEN="$(jq -r .root_token "/tmp/$id.json")" \
  vault write sys/replication/performance/secondary/enable token="$token" ca_file=/vault/tls/ca.pem


sleep 5 #? specific endpoint to guarantee no transient failure due to #too-soon
for i in "${instances[@]:1}"; do
  VAULT_ADDR="https://localhost:$(docker inspect "$i" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')" \
    vault operator unseal "$(jq -r .unseal_keys_b64[0] ../secrets/init.json)" >/dev/null &
done

# configure autopilot
echo "# configure autopilot"
token="$(vault login -token-only -method=userpass username=admin password=admin)"
VAULT_TOKEN=$token vault operator raft autopilot set-config -cleanup-dead-servers=true -min-quorum=3 -dead-server-last-contact-threshold=2m # sys/storage/raft/autopilot
VAULT_TOKEN=$token vault token revoke -self

wait