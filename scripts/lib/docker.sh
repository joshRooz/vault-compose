#!/usr/bin/env bash

get_instances() {
  local -n insts=${1:?}
  local id=${2:?}
  local project=${3:?}
  local i
  local delim="@" # use a character that is not allowed in a container name

  i="$(
    docker ps \
    --filter "name=${project}-${id}" \
    --format "{{.Names}}" |
    sort
  ) ${delim}"
  # shellcheck disable=SC2034  # array is a reference
  read -d "${delim}" -ra insts <<<"$i"
}


get_port() {
  local container=${1:?}
  local container_port=${2:-8200}

  docker inspect "$container" |
  jq --arg cp "$container_port/tcp" -r '.[].NetworkSettings.Ports.[$cp].[].HostPort'
}


_get_all_aliases() {
  local id=${1:-${id:?"a container id is required"}}

  all="$(
    docker inspect example.internal |
    jq -r '[ .[].Containers | (to_entries).[] | [.value.Name,.key[:12],.value.IPv4Address] ]'
  )"
  jq -r --arg id "$id" '.[] | select(index($id))' <<<"$all"
}


get_container_name() {
  local id=${1:-${id:?"a container id is required"}}

  jq -r '.[0]' <<<"$(_get_all_aliases "$id")"
}


get_ip() {
  local id=${1:-${id:?"a container id is required"}}

  jq -r '.[2]' <<<"$(_get_all_aliases "$id")"
}
