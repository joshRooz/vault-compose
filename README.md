# Vault Compose - Replication

## Usage
```sh
make up
export VAULT_CACERT=$(pwd)/tls/root-ca/dev-root-ca.pem

# primary cluster
make show-ports-lb
export VAULT_ADDR=https://localhost:<vault-lb-usca-443-port-mapping>
export VAULT_TOKEN=$(jq -r .root_token secrets/init.json)
vault operator raft list-peers

# primary cluster - haproxy stats
# browser -> http://localhost:<vault-lb-usca-9000-port-mapping>/stats;up
```

## Cluster Topology

Four clusters are deployed:
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

### DR Failover
Failover **USCA** to **USIL**

\#TODO
