# Test Case 1: CP Node Failure and Replacement

Simulate a control plane node failure, observe cluster behavior, and replace the failed node.

Requires: `control_plane_count = 3`, `hcloud` CLI configured.

## 1. Kill the node

```bash
make test-kill-node-cp N=1 DEBUG=1
```

Server is powered off via Hetzner API. After ~40s Kubernetes marks it as `NotReady`.

```
=== Powering off k8s-lab-cp-1 (x.x.x.x) via Hetzner API ===
Server 123018588 stopped
```

## 2. Observe the damage

```bash
kubectl get nodes
```

```
NAME               STATUS     ROLES           AGE   VERSION
k8s-lab-cp-0       Ready      control-plane   83m   v1.35.2
k8s-lab-cp-1       NotReady   control-plane   81m   v1.35.2
k8s-lab-cp-2       Ready      control-plane   80m   v1.35.2
k8s-lab-worker-0   Ready      <none>          79m   v1.35.2
k8s-lab-worker-1   Ready      <none>          79m   v1.35.2
```

API still responds. CP-1 is `NotReady` but the cluster functions normally.

```bash
make show-etcd-status
```

CP-1 endpoint fails, CP-0 (leader) and CP-2 (follower) are healthy:

```
Failed to get the status of endpoint https://10.0.1.11:2379 (context deadline exceeded)
+------------------------+------------------+---------+...+-----------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |
+------------------------+------------------+---------+...+-----------+
| https://10.0.1.10:2379 | 22ea434a682f6cd4 |   3.6.6 |...|      true |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |
+------------------------+------------------+---------+...+-----------+
```

```bash
make show-events
```

```
kube-system   Warning   NodeNotReady   pod/etcd-k8s-lab-cp-1                      Node is not ready
kube-system   Warning   NodeNotReady   pod/kube-apiserver-k8s-lab-cp-1            Node is not ready
kube-system   Warning   NodeNotReady   pod/kube-controller-manager-k8s-lab-cp-1   Node is not ready
kube-system   Warning   NodeNotReady   pod/kube-scheduler-k8s-lab-cp-1            Node is not ready
kube-system   Warning   NodeNotReady   pod/calico-node-9428b                      Node is not ready
default       Normal    NodeNotReady   node/k8s-lab-cp-1                          Node k8s-lab-cp-1 status is now: NodeNotReady
```

```bash
make show-etcd-logs N=0
```

etcd on surviving nodes detects the peer is unreachable:

```
"msg":"prober detected unhealthy status","remote-peer-id":"f34b339eb4788f20","error":"dial tcp 10.0.1.11:2380: i/o timeout"
"msg":"failed to reach the peer URL","address":"https://10.0.1.11:2380/version","error":"...i/o timeout"
```

The cluster continues to function because etcd has quorum (2/3 members).

## 3. Remove all traces of the lost node

```bash
make etcd-remove-member N=1
```

This automatically:
- Finds the etcd member ID by internal IP
- Removes the member from etcd cluster
- Deletes the node from Kubernetes

```
=== Removing etcd member f34b339eb4788f20 (10.0.1.11) from cluster ===
Member f34b339eb4788f20 removed from cluster 83a0d682cdf75ee3

=== Deleting node from Kubernetes ===
node "k8s-lab-cp-1" deleted

Done. Now recreate the server:
  cd terraform && terraform apply -replace='hcloud_server.control_plane[1]' -replace='hcloud_server_network.control_plane[1]' && cd ..
  make inventory && make bootstrap && make common && make cp
```

### Verify clean state

```bash
make show-etcd-status                # only 2 members, no timeouts
```

```
+------------------------+------------------+---------+...+-----------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |
+------------------------+------------------+---------+...+-----------+
| https://10.0.1.10:2379 | 22ea434a682f6cd4 |   3.6.6 |...|      true |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |
+------------------------+------------------+---------+...+-----------+
```

## 4. Create a replacement node

```bash
# Recreate the server (-replace forces destroy + create)
cd terraform
terraform apply -replace='hcloud_server.control_plane[1]' -replace='hcloud_server_network.control_plane[1]'
cd ..

# Join the new server to the cluster
make inventory
make bootstrap
make common
make cp
```

The new node gets the same internal IP (10.0.1.11, assigned statically in terraform) and joins as a fresh etcd member with a new member ID.

### Verify recovery

```bash
make show-etcd-status
```

All 3 members healthy, raft index synchronized:

```
+------------------------+------------------+---------+...+-----------+...+-----------+------------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |...| RAFT TERM | RAFT INDEX |
+------------------------+------------------+---------+...+-----------+...+-----------+------------+
| https://10.0.1.10:2379 | 22ea434a682f6cd4 |   3.6.6 |...|      true |...|         2 |      33971 |
| https://10.0.1.11:2379 | 7c9f8e28614393e6 |   3.6.6 |...|     false |...|         2 |      33971 |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |...|         2 |      33971 |
+------------------------+------------------+---------+...+-----------+...+-----------+------------+
```

Note: CP-1 has a new member ID (`7c9f8e28614393e6` vs original `f34b339eb4788f20`). This is expected -- it's a new etcd member, not the old one recovered.

```bash
make smoke-test                      # full health check
```

## Summary

| Step | Command | What happens |
|------|---------|--------------|
| Kill | `make test-kill-node-cp N=1` | Server powered off, etcd loses 1 member |
| Observe | `make show-etcd-status`, `make show-events`, `make show-etcd-logs` | Timeout errors, NodeNotReady |
| Clean | `make etcd-remove-member N=1` | Removes etcd member + deletes k8s node |
| Replace | `terraform apply -replace=...` + `make cp` | New server, fresh etcd join |
| Verify | `make show-etcd-status`, `make smoke-test` | 3 healthy members, raft synced |
