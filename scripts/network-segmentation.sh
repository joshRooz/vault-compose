#!/usr/bin/env bash
set -oeu pipefail

usage() { 
  echo "Usage: $0 -m <mode> [-n <network>] -i <context> -s <source_context> -c <compose_project>

    -m  Segmention mode. Valid values are 'allow' or 'deny'.
    -n  Optional, Docker network name. Default 'vault-flat'.
    -i  Destination cluster or load balancer context. Segmentation will be applied to this container(s).
    -s  Source clsuter or load balancer context. Segmentation will be updated with this container(s).
    -c  Docker compose project name.

    Example: 'hcv-a' cluster will deny traffic sourced from 'hcv-b' cluster
    $0 -m deny -i hvc-a -s hvc-b -c vault" 1>&2
}

network=vault-flat
while getopts "m:i:s:n:c:" options ; do
  case "${options}" in
    m)  if [[ ! ${OPTARG} =~ ^(allow|deny)$ ]] ; then
          usage && exit 1
        fi
        mode="${OPTARG}"
        ;;
    i) dest="${OPTARG}" ;;
    s) source="${OPTARG}" ;;
    c) project="${OPTARG}" ;;
    n) network="${OPTARG}" ;;
    *) usage && exit 1 ;;
  esac
done

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
source "$SCRIPT_DIR/common.sh"

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

  #docker exec --privileged -u root "$container" sh -c "apk add iptables ipset" &>/dev/null
  install_pkgs "$container"
  docker exec --privileged -u root "$container" sh -c "ipset create -! $segment hash:ip"
  docker exec --privileged -u root "$container" sh -c "iptables -A INPUT -m set --match-set $segment src -j DROP"
}

# shellcheck disable=SC2120
deny_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${dests[@]}" ; do
    create_segment "$i" "$segment" &
  done
  wait

  for i in "${dests[@]}" ; do
    for ip in "${src_ips[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset add -! $segment $ip" &
    done
  done
  wait
}

# shellcheck disable=SC2120
allow_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${dests[@]}" ; do
    for ip in "${src_ips[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset del -! $segment $ip" &
    done
  done
  wait
}


#---------------------------------------------------------------------
# get the source container ip(s)
containers="$(docker network inspect "$network" | jq .[].Containers)"

srcs=()
get_instances srcs "$source"

dests=()
get_instances dests "$dest"

src_ips=()
for src in "${srcs[@]}" ; do
  ip="$(jq -r --arg src "$src" '.[] | select(.Name == $src).IPv4Address | sub("(?<x>(.)+)/[0-9]+" ; "\(.x)")' <<< "$containers")"
  src_ips+=("$ip")
done

case "${mode}" in
  "deny") deny_traffic ;;
  "allow")  allow_traffic ;;
esac
