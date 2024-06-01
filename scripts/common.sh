#!/usr/bin/env bash

get_instances() {
  local -n insts=${1:?}
  local id=${2:-${id:?}}
  local project=${3:-${project:?}}
  local i
  local delim="@" # use a character that is not allowed in a container name

  i="$(docker ps --filter "name=${project}-${id}" --format "{{.Names}}" | sort) ${delim}"
  # shellcheck disable=SC2034  # array is a reference
  read -d "${delim}" -ra insts <<<"$i"
}


unseal_with_retry() {
  # there's a period of time where vault has been initialized but storage isn't quite ready
  # on the remaining instances. retry in the background until we succeed
  local container=${1:?}
  local port
  local token
  
  port="$(docker inspect "$container" | jq -r '.[].NetworkSettings.Ports."8200/tcp".[].HostPort')"
  token="$(jq -r .unseal_keys_b64[0] ../secrets/init.json)"
  until VAULT_ADDR="https://localhost:$port" vault operator unseal "$token" &>/dev/null ; do
    sleep 2
  done
  echo "Success! Unsealed: $container"
}
