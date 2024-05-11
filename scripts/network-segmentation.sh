#!/usr/bin/env bash
set -oeu pipefail

# could use docker 'compose ps --services' to simplify config, but depends on what 
# type of service distruptions we want to emulate
# ie  $0 -i vaulta -s vaultc

usage() { 
  echo "Usage: $0 -m <mode> [-n <network>] -i <instance> -s <source>

    -m  string. Segmention mode. Valid values are 'allow' or 'deny'.
    -n  string. Optional, Docker network name. Default 'vault-flat'.
    -i  list(string). Destination container name. Segmentation will be applied to this container.
    -s  list(string). Source container name. Segmentation will be updated with this container.

    Example: 'hcv-a' cluster will deny traffic sourced from 'hcv-b' cluster  
    $0 -m deny -i hvc-a01 -i hvc-a02 -i hvc-a03 -s hvc-b01 -s hvc-b02 -s hvc-b03" 1>&2
}

network=vault-flat
while getopts "m:i:s:n:" options ; do
  case "${options}" in
    m)  if [[ ! ${OPTARG} =~ ^(allow|deny)$ ]] ; then
          usage && exit 1
        fi
        mode="${OPTARG}"
        ;;
    i) instances+=("${OPTARG}") ;;
    s) sources+=("${OPTARG}") ;;
    n) network="${OPTARG}" ;;
    *) usage && exit 1 ;;
  esac
done


create_segment() {
  local container=${1:?}
  local segment=${2:?}

  docker exec --privileged -u root "$container" sh -c "apk add iptables ipset" &>/dev/null
  docker exec --privileged -u root "$container" sh -c "ipset create -! $segment hash:ip"
  docker exec --privileged -u root "$container" sh -c "iptables -A INPUT -m set --match-set $segment src -j DROP"
}

# shellcheck disable=SC2120
deny_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${instances[@]}" ; do
    create_segment "$i" "$segment" &
  done
  wait

  for i in "${instances[@]}" ; do
    for ip in "${src_ips[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset add -! $segment $ip" &
    done
  done
  wait
}

# shellcheck disable=SC2120
allow_traffic() {
  local segment=${1:-"blacklist"}

  for i in "${instances[@]}" ; do
    for ip in "${src_ips[@]}" ; do
      docker exec --privileged -u root "$i" sh -c "ipset del -! $segment $ip" &
    done
  done
  wait
}


# get the source container ip(s)
containers="$(docker network inspect "$network" | jq .[].Containers)"
src_ips=()
for src in "${sources[@]}" ; do
  ip="$(jq -r --arg src "$src" '.[] | select(.Name == $src).IPv4Address | sub("(?<x>(.)+)/[0-9]+" ; "\(.x)")' <<< "$containers")"
  src_ips+=("$ip")
done

case "${mode}" in
  "deny") deny_traffic ;;
  "allow")  allow_traffic ;;
esac
