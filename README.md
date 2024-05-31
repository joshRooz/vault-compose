# Vault Compose

## Cluster Topology

Four clusters, running in logical redundancy zones (1, 2, and 3), are deployed to a flat network. The primary cluster has six instances as the reference architecture states. To minimize weight the remaining clusters are set to 3 replicas, but can scale all the same. An HAProxy instance fronts each cluster, with dynamic ports forwarded for the Vault API and HAProxy statistics.


The HAProxy configuration contains a commented KMIP frontend and backend as well.

- **USCA** - San Francisco, CA
- **USNY** - New York, NY
- **USIL** - Chicago, IL
- **USTX** - Austin, TX

### Steady State
- *Primary* - **USCA**
- *Perf Secondary* - **USNY**
- *DR Secondary* - **USIL**
- *DR Secondary [off Perf Secondary]* - **USTX**

![cluster-topology-image](docs/topology.png)

## Usage
```sh
task up
export VAULT_CACERT=$(pwd)/tls/root-ca/dev-root-ca.pem

# primary cluster
task show-ports-lb
export VAULT_ADDR=https://localhost:<vault-lb-usca-443-port-mapping>
export VAULT_TOKEN=$(jq -r .root_token secrets/init.json)
vault operator raft list-peers

# primary cluster - haproxy stats
# browser -> http://localhost:<vault-lb-usca-9000-port-mapping>/stats;up


# do.the.vaulting.


# clean-up
task down
```

## Auto Upgrades

### High Level Steps
1. Develop and test desired change (eg: Vault version, underlying AMI - OS release or configuration, etc.)
1. Increment the cluster version (ie: `storage.autopilot_upgrade_version`) in the Vault configuration (`CLUSTER_VERSION` environment variable below)
1. *Scale out* the deployment instances by a factor of 2 (eg: 6 to 12). If the previous upgrade version was `0.0.1` with six instances, trigger a new deployment of the same size with the new tag (eg: `0.0.2`).
1. If not using auto-unseal, unseal the new deployment instances.
1. Autopilot recognizes the new version's tag and they will join the cluster as non-voters.
1. Once autopilot detects that the count of nodes on the new version equals or exceeds older version nodes, it begins promoting the new nodes to voters and demoting the older version nodes to non-voters one-by-one.
1. The raft leader (and active node) will be transfered, then demoted last.
1. A status of `await-server-removal` means that the demoted instances can be terminated.
1. Autopilot will clean-up the dead instances according to the configuration.


### Walk-through

> **NOTE**: Cluster upgrade order is very important in practice (and this is *not* the right order), but here we are throwing caution to the wind.
>           For more information checkout: https://developer.hashicorp.com/vault/docs/upgrading#enterprise-replication-installations

1. Add the following service to the `compose.yaml` file. This mimics scaling up before decommissioning the existing instances. Notice the `CLUSTER_VERSION` is incremented to `0.0.2`.
    ```yaml
    usca-v2:
      image: ${VAULT_IMAGE}:${VAULT_VERSION}
      command: *vault-command
      restart: unless-stopped
      deploy:
        replicas: 6
      networks: *vault-flat
      ports: *vault-ports
      environment:
        <<: *vault-env-vars
        CLUSTER_VERSION: 0.0.2
      configs: *usca-configs
      secrets: *usca-secrets
      cap_add: *vault-capabilities
    ```

1. Start the `usca-v2` service, which results in 6 new cluster "nodes."
    ```sh
    docker compose up -d
    ```

1. In a second session watch the autopilot configuration.
    ```sh
    #tmux  # optional. split into two horizontal panes with ctrl+b + double-quote
    watch 'vault operator members  ; echo ; vault operator raft list-peers'
    ```

1. Unseal the new nodes in the first session.
    ```sh
    pushd scripts
    . ./common.sh

    i="$(docker ps --filter "name=vault-usca-v2" --format "{{.Names}}" | sort) @"
    read -d "@" -ra instances <<<"$i"
    for i in "${instances[@]}" ; do
      unseal_with_retry "$i" &
    done
    wait

    popd
    ```

1. Wait until the `Status` is *await-server-removal* and the `TargetVersion` is *0.0.2*.
    ```sh
    vault operator raft autopilot state --format=json | jq '.Upgrade | {Status,TargetVersion}'
    # vault operator raft autopilot state --format=json | jq '.Servers[] | select(.UpgradeVersion == "0.0.1")' # optional. server specific information
    ```

1. Terminate the previous set of instances.
    ```sh
    # in session one -
    docker compose rm -sf usca
    ```

1. Autopilot will recognize the instances have been terminated and they will drop-off the members list, then peers lists. At that point autopilot status will become *idle*.
    ```sh
    vault operator raft autopilot state --format=json | jq '.Upgrade.Status'
    ```


## Dependencies
- Docker Compose
- OpenSSL
- Bash
- JQ
- Optional: Taskfile or Make - *NOTE:both use the compose plugin as opposed to the docker-compose standalone binary*

**Taskfile vs Makefile**:
Taskfile is the successor to Make in this repository. Since Make is commonly available by default, it has been left in the repo as-is (for now).

- Taskfile calls role specific scripts - `init-primary.sh`, `init-perf-replica.sh`, `init-dr-secondary.sh`
- Taskfile also orchestrates failover scenarios using - `network-segmentation.sh`
- Makefile uses a single, hardcoded script - `init-steady-state.sh`
