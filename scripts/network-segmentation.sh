#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -m <mode> -i <context> -s <source_context> -c <compose_project>

    -m  Segmention mode. Valid values are 'allow' or 'deny'.
    -i  Destination cluster or load balancer context. Segmentation will be applied to this container(s).
    -s  Source cluster or load balancer context. Segmentation will be updated with this container(s).
    -c  Docker compose project name.

    Example: 'usca' cluster will deny traffic sourced from 'usny' cluster
    $0 -m deny -i usca -s usny -c vault" 1>&2
}

while getopts "m:i:s:c:" options ; do
  case "${options}" in
    m)  if [[ ! ${OPTARG} =~ ^(allow|deny)$ ]] ; then
          usage && exit 1
        fi
        mode="${OPTARG}"
        ;;
    i) dest="${OPTARG}" ;;
    s) source="${OPTARG}" ;;
    c) project="${OPTARG}" ;;
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
install_pkgs() {
  local container=${1:?}
  local pkg_cmd

  shopt -s nocasematch
  os="$(docker exec "$container" sh -c "awk -F= '/^ID=/ {print \$NF}' /etc/os-release")"
  case "${os}" in
    alpine) pkg_cmd="apk add" ;;
    debian|ubuntu) pkg_cmd="apt-get update && apt-get install -y" ;;
  esac
  shopt -u nocasematch

  docker exec --privileged -u root "$container" sh -c "$pkg_cmd iptables ipset" &>/dev/null
}


create_segment() {
  local container=${1:?}
  local segment=${2:?}

  install_pkgs "$container"
  docker exec --privileged -u root "$container" sh -c "ipset create -! $segment hash:ip"
  docker exec --privileged -u root "$container" sh -c "iptables -A INPUT -m set --match-set $segment src -j DROP"
}


# shellcheck disable=SC2120
deny_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${DESTS[@]}" ; do
    create_segment "$i" "$segment" &
  done
  wait

  for i in "${DESTS[@]}" ; do
    for ip in "${SRC_IPS[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset add -! $segment $ip" &
    done
  done
  wait
}


# shellcheck disable=SC2120
allow_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${DESTS[@]}" ; do
    for ip in "${SRC_IPS[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset del -! $segment $ip" &
    done
  done
  wait
}


#---------------------------------------------------------------------
SRCS=()
DESTS=()

get_instances SRCS "$source" "$project"
get_instances DESTS "$dest" "$project"

SRC_IPS=()
for src in "${SRCS[@]}" ; do
  ip=$(get_ip "$src")
  SRC_IPS+=( "${ip%/*}" )
done

case "${mode}" in
  "deny") deny_traffic ;;
  "allow")  allow_traffic ;;
esac