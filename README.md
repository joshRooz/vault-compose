# Vault Compose

## Cluster Topology

Four clusters, running in logical redundancy zones (1, 2, and 3), are deployed to a flat network. The primary cluster has six instances as specified by the reference architecture. To minimize environment overhead, the remaining clusters are set to 3 replicas, but can scale all the same. An HAProxy instance fronts each cluster, with dynamic ports forwarded for the Vault API and HAProxy statistics.

Git tags (`direct-replication` or `lb-replication`) dictate when the cluster replication targets HAProxy or the cluster directly.

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
Common configuration is defined in `.env`. Defaults should work out-of-the-box in *most* cases.
1. **Vault License** | `VAULT_LICENSE_PATH` - Set to the location of your license file.
1. **Vault Version** | `VAULT_IMAGE` and `VAULT_VERSION` - Set as desired.
1. **Telemetry Logs** | `PROMTAIL_DOCKER_SOCKET` - In an attempt to maximize portability and minimize dependencies, the Docker API is exposed to Promtail. Be sure to update if your Docker configuration does not match `/var/run/docker.sock`.

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

# shared telemetry stack
# prometheus -> http://localhost:9090
# grafana -> http://localhost:3000

# clean-up
task down
task delete-volumes # removes loki, prometheus, and grafana volumes
```

## Telemetry
The environment ships *logs* (operational and audit) and *metrics* to Grafana.

Dashboards will be added as time permits.

**LogQL Helpers**
```logql
{service="vault"} | json | _level != "" # all vault ops logs
{service="vault"} | json | type != ""   # all vault audit logs
```

## Replication

### Networking Requirements
Replication relies on a gRPC connection initiated by the secondary (pull model) with a hard dependency on the cluster address (8201/tcp by default).

There are two ways to establish replication with differing networking requirements -
1. A one-time request to the primary API address (8200/tcp default) to unwrap the token generated on the primary. Replication is then established over the cluster address (8201/tcp default) using the token.
1. Encrypting the token generated on the primary using a public key from the secondary. Replication is then established over the cluster address (8201/tcp default) using the token.

The performance replication [script](./scripts/init-perf-replica.sh) uses the wrapped token method. Meanwhile, the DR replication [script](./scripts/init-dr-secondary.sh) uses the public key method to establish replication.

With those two methods mind, **cross-cluster networking requirements** are as follows -
Source | Destination | Port | Description
---|---|---|---
Secondary | Primary | 8201/tcp | The **cluster address** must always be available<br/>on the *active node only* of the primary cluster.
Secondary | Primary | 8200/tcp | The **API** must be accessible if and only if token<br/>wrapping is used to initiate replication.

> **NOTE**: Make sure to consider role-swapping scenarios when applying networking rules.

### Topology Mobility

Once replication is enabled the topology becomes mobile. This section steps through cluster role transitions.

#### Graceful Disaster Recovery Role Reversal
Controlled scenario that ensures data is fully replicated, and data integrity is intact.

Scenario: From [steady state](#steady-state), demote **USCA** and promote **USIL**.

1. Pre-flight validations for replication health.
1. Communicate the role reversal window's start.
1. Disable USCA API/KMIP traffic.
1. Demote USCA to secondary.
1. Promote USIL to primary.
1. Test access to Vault data while USIL as the primary.
1. Update DNS/mechanisms to direct client traffic to USIL.
1. Enable replication for USCA as a secondary, with USIL as primary.

**Checkpoint**: Primary and DR replica roles have been reversed, with client traffic now being directed to the new primary.

1. Validate or redirect perf replication to the new primary.

Run Demo: `task topology:swap-dr-roles`


#### Disaster Recovery Promotion
A "break the glass" scenario where there is potential for data loss.

Scenario: From [steady state](#steady-state), **USCA** fails; activate **USIL**.

1. Declare a disaster due to serverly impacted USCA availability.
1. Isolate USCA (failed primary) to prevent any potential for a split-brain scenario.
1. Activate USIL as the primary.
1. Test access to Vault data with USIL as the primary.
1. Update DNS/mechanisms to direct client traffic to USIL.

**Checkpoint**: At this point, the failed primary and new DR primary both have the primary role assignment. The new primary receives all client traffic, and the failed primary is isolated to prevent any requests from clients when it comes back online.

1. Validate or redirect performance replication to the new primary.

**Checkpoint**: Service interruption for the **USCA** cluster is resolved.

1. Recover, replace, restore, demote the USCA failed primary.
1. Point USCA to UNSY for replication.
1. Remove USCA from isolation/quarantine.
1. *(optional)* Plan and schedule failback, following the graceful procedure.

Run Demo: `task topology:promote-dr-secondary`


#### Performance Replication Role Reversal

Scenario: From [steady state](#steady-state), demote **USCA** to a performance secondary and promote **USNY** to performance primary.

> **NOTE**: If the primary cluster has both a Disaster Recovery (DR) replica and a Performance Replica (PR), as in this demo environment, a PR role reversal is unlikely to be the desired course of action.
>
> Assuming replication is current, [DR role changes](#graceful-disaster-recovery-role-reversal) will retain tokens and leases and is preferred [in most cases] for role reversal.

1. Schedule an outage window to demote USCA.
1. Disable USCA API/KMIP traffic.
1. Demote USCA to secondary.
1. Promote USNY to primary.
1. Update replication for USCA as secondary.
1. Enable USCA API/KMIP traffic.
1. Update DNS/mechanisms that client traffic relies upon.

**Checkpoint**: Primary and performance replica roles have been reversed.

1. If there are other secondaries, they need to be updated with the new primary address as well.

Run Demo: `task topology:swap-perf-roles`


#### Performance Replication Promotion

Scenario: From [steady state](#steady-state), **USCA** fails; promote **USNY** to performance primary.

> **NOTE**: If the primary cluster has both a DR replica and a PR replica, as in this demo environment, promoting a PR is likely the last option:
>   1. Resolve the primary cluster's service outage.
>   1. Perform [DR Activation](#disaster-recovery-activation) and redirect the PR to the new primary.
>   1. If the service outage also impacts the DR cluster (root cause analysis is imperative), promoting the PR becomes the best option.
>
> With a PR promotion, all clients previously connecting to the failed primary must reauthenticate after failover. There are also PKI considerations.

1. Declare a disaster due to serverly impacted USCA availability.
1. Decide to activate USNY.
1. Isolate USCA, the failed primary, to prevent any potential split-brain scenario.
1. Promote USNY to primary.
1. Test access to Vault data with USNY as the primary.
1. Update DNS/mechanisms that client traffic relies upon.

**Checkpoint**: The primary role has been restored, and client traffic is now directed to the new primary. If there are other secondaries, they need to be updated with the new primary as well.

1. Recover, replace, restore, demote the USCA failed primary.
1. Disable USCA isolation.
1. Enable replication for USCA as a secondary, with USNY as primary.
1. *(optional)* Plan and schedule failback, following the graceful procedure.

Run Demo: `task topology:promote-perf-replica`

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

1. **Optional**: Make the changes outlined in [Appendix - Reliable but Slow](#appendix---reliable-but-slow) in `vault.tpl.hcl`.
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
    export VAULT_CACERT=$(pwd)/tls/root-ca/dev-root-ca.pem
    pushd scripts
    . ./common.sh

    instances=()
    get_instances instances usca-v2 vault
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


## Redundancy Zones

### Read Scaling Walk-through

**Optional Prerequisite**: Make the changes outlined in [Appendix - Reliable but Slow](#appendix---reliable-but-slow) in `vault.tpl.hcl`. Required if you remove the first three instances (eg: `vault-usca-1`).

```sh
# checkout the starting state
vault operator raft autopilot state
vault operator members  ; echo ; vault operator raft list-peers

# scale to a voter + 4 non-voters in each zone
docker compose scale usca=15
task vault-unseal cluster=usca

# --------------------------------
# scale back down to a single voter and single non-voter in each zone
docker compose scale usca=6

# autopilot will remove from members list ~10s last contact threshold
# autopilot will clean-up at ~2m dead server last contact threshold
watch 'vault operator raft autopilot state ; echo ; vault operator members  ; echo ; vault operator raft list-peers'
```

## Dependencies
- Docker Compose
- OpenSSL
- Bash
- JQ 1.7+[^1]
- [Taskfile](https://taskfile.dev/installation) *(optional)*

> **NOTE**: While Taskfile (`task`) is optional it is used to orchestrate the environment and will make deployment a push button exercise. At a minimum, checkout `Taskfile.dist.yml` for the steps to run on your own.

[^1]: JQ 1.6 may produce the following error -

      ```sh
      jq: error: syntax error, unexpected '[', expecting FORMAT or QQSTRING_START (Unix shell quoting issues?) at <top-level>, line 1:
      .[].NetworkSettings.Ports."8200/tcp".[].HostPort
      jq: 1 compile error
      ```

# References
- [HashiCorp Support - Replication without API and wrapped token](https://support.hashicorp.com/hc/en-us/articles/4417477729939-How-to-enable-replication-without-using-either-a-response-wrapped-token-or-port-8200)
- [HashiCorp Tutorials - Enable DR Replication](https://developer.hashicorp.com/vault/tutorials/enterprise/disaster-recovery#enable-dr-primary-replication)
- [HashiCorp Tutorials - Setup Performance Replication](https://developer.hashicorp.com/vault/tutorials/enterprise/performance-replication)
- [HashiCorp Tutorials - DR Replication Failover](https://developer.hashicorp.com/vault/tutorials/enterprise/disaster-recovery-replication-failover)

# Appendix - Reliable but Slow
The Vault `retry_join {}` configuration can be altered to be more resilient to lifecycle changes, but it is signficantly slower to deploy.

```diff
 storage "raft" {
   autopilot_redundancy_zone = "{{AZ}}"
   autopilot_upgrade_version = "{{CLUSTER_VERSION}}"
   retry_join {
+    leader_api_addr       = "https://{{CLUSTER_CONTEXT}}:8200"
-    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-1.{{DOMAIN}}:8200"
     leader_ca_cert_file   = "/vault/tls/ca.pem"
     leader_tls_servername = "{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
   }
-  retry_join {
-    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-2.{{DOMAIN}}:8200"
-    leader_ca_cert_file   = "/vault/tls/ca.pem"
-    leader_tls_servername = "{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
-  }
-  retry_join {
-    leader_api_addr       = "https://vault-{{CLUSTER_CONTEXT}}-3.{{DOMAIN}}:8200"
-    leader_ca_cert_file   = "/vault/tls/ca.pem"
-    leader_tls_servername = "{{CLUSTER_CONTEXT}}.{{DOMAIN}}"
-  }
 }
```