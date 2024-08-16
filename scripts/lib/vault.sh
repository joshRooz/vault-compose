#!/usr/bin/env bash

get_leader() {
  local id=${1:?"cluster context required"}
  local project=${2:-${project:?"compose project required"}}
  local port
  local leader

  # go through the lb so we get a working node, as long as we have a quorum
  port="$(get_port "${project}-lb-${id}-1" 443)"
  if ! leader="$(VAULT_ADDR="https://localhost:$port" vault status -format=json | jq -r .leader_address)" ; then
    return 1
  fi
  leader="${leader#https://}"
  leader="${leader%:8200}"

  echo "$leader"
}


get_admin_token() {
  local id=${1:?"cluster context required"}
  local project=${2:-${project:?"compose project required"}}

  port="$(get_port "${project}-lb-${id}-1" 443)"
  VAULT_ADDR="https://localhost:$port" \
    vault login -token-only -method=userpass username=admin password=admin
}


unseal() {
  # there's a period of time where vault has been initialized but storage isn't quite ready
  # on the remaining instances. retry in the background until we succeed
  local container=${1:?}
  local port
  local key
  
  port="$(get_port "${container}")"
  key="$(jq -r .unseal_keys_b64[0] ../secrets/init.json)"

  until VAULT_ADDR="https://localhost:$port" vault operator unseal "$key" &>/dev/null ; do
    sleep 2
  done
  echo "# unsealed: $container"
}


# if using set -e / errexit disable it for this function call, we expect the leader to fail at some point
seal() {
  local id=${1:?"cluster context required"}
  local project=${2:?${project:?"compose project required"}}
  local token
  local bq # break quorum counter
  local leader
  local max=6 # get_leader maximum retries
  local cnt=0 # get_leader retry counter

  # veriy we have a leader and are not a DR cluster
  if ! get_leader "$id" "$project" &>/dev/null ; then
    echo "# no leader found"
    return 1
  fi

  token="$(get_admin_token "$id" "$project")"

  bq=$(( ${#INSTANCES[@]} / 2 )) # remove the +1 offset as loop starts at 0
  for ((i=0; i<=bq; i++)) ; do
    # might get a case of the step-down jitters along the way
    until leader="$(get_leader "$id" "$project")" ; do
      [ $cnt -ge $max ] && return 0 # edge cases here but demo
      (( cnt++ ))
      sleep 2
    done
    echo "# sealing: $(get_container_name "$leader")"
    docker exec "$leader" curl -s -S -k https://localhost:8200/v1/sys/seal -H "X-Vault-Token: $token" -X POST
  done

  # sealing the remaining nodes requires reconcilation logic to
  # determine which nodes haven't been sealed.
  # maybe later...

  # token is left dangling because we cannot be a good citizen
  # without a cluster to talk to.
}
