# Test Case 2: etcd Leader Failover

Kill the etcd leader (CP-0), observe new leader election, verify API continues, recover.

Requires: `control_plane_count = 3`, `hcloud` CLI configured.

**What makes this different from test case 1:**
- Test case 1: kill a **follower** (CP-1), remove + replace permanently
- Test case 2: kill the **leader** (CP-0), observe election, recover (no replacement needed)

## 0. Identify the current leader

```bash
make show-etcd-status
```

```
+------------------------+------------------+---------+...+-----------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |
+------------------------+------------------+---------+...+-----------+
| https://10.0.1.10:2379 | 22ea434a682f6cd4 |   3.6.6 |...|      true |
| https://10.0.1.11:2379 | 7c9f8e28614393e6 |   3.6.6 |...|     false |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |
+------------------------+------------------+---------+...+-----------+
```

CP-0 (10.0.1.10) is the leader. This is typically the init node (the one that ran `kubeadm init`).

## 1. Kill the leader

```bash
make test-kill-node-cp N=0 DEBUG=1
```

Server is powered off via Hetzner API. This is the most disruptive CP failure possible -- the etcd leader and the original init node go down simultaneously.

```
=== Powering off k8s-lab-cp-0 (x.x.x.x) via Hetzner API ===
Server 123456789 stopped
```

## 2. Observe leader election

```bash
make show-etcd-status
```

etcd elects a new leader from the remaining members. The raft term increments:

```
Failed to get the status of endpoint https://10.0.1.10:2379 (context deadline exceeded)
+------------------------+------------------+---------+...+-----------+...+-----------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |...| RAFT TERM |
+------------------------+------------------+---------+...+-----------+...+-----------+
| https://10.0.1.11:2379 | 7c9f8e28614393e6 |   3.6.6 |...|      true |...|         3 |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |...|         3 |
+------------------------+------------------+---------+...+-----------+...+-----------+
```

Key observations:
- New leader elected (CP-1 or CP-2, depends on who responds first)
- Raft term incremented (was 2, now 3) -- confirms a real election happened
- Election is fast (~seconds), much faster than node failure detection (~40s)

### API continues via load balancer

```bash
kubectl get nodes
```

```
NAME               STATUS     ROLES           AGE   VERSION
k8s-lab-cp-0       NotReady   control-plane   90m   v1.35.2
k8s-lab-cp-1       Ready      control-plane   88m   v1.35.2
k8s-lab-cp-2       Ready      control-plane   87m   v1.35.2
k8s-lab-worker-0   Ready      <none>          86m   v1.35.2
k8s-lab-worker-1   Ready      <none>          86m   v1.35.2
```

The LB routes API traffic to the remaining CP nodes. `kubectl` works without any reconfiguration.

```bash
make show-etcd-logs N=1
```

etcd logs on surviving nodes show the election:

```
"msg":"leader changed","leader-id":"7c9f8e28614393e6"
"msg":"prober detected unhealthy status","remote-peer-id":"22ea434a682f6cd4","error":"...i/o timeout"
```

### Verify the init node is not special

Deploy a test pod to prove the cluster is fully operational without CP-0:

```bash
kubectl run test-pod --image=nginx:stable-alpine --restart=Never
kubectl get pod test-pod
kubectl delete pod test-pod
```

This confirms that CP-0 (the init node) has no special role after cluster bootstrap. All CP nodes are equal members.

## 3. Recover the old leader

```bash
make test-recover-node-cp N=0 DEBUG=1
```

```
=== Powering on k8s-lab-cp-0 (x.x.x.x) via Hetzner API ===
Server 123456789 started
```

After ~30s the node rejoins:

```
NAME               STATUS   ROLES           AGE   VERSION
k8s-lab-cp-0       Ready    control-plane   95m   v1.35.2
k8s-lab-cp-1       Ready    control-plane   93m   v1.35.2
k8s-lab-cp-2       Ready    control-plane   92m   v1.35.2
k8s-lab-worker-0   Ready    <none>          91m   v1.35.2
k8s-lab-worker-1   Ready    <none>          91m   v1.35.2
```

### Old leader rejoins as follower

```bash
make show-etcd-status
```

```
+------------------------+------------------+---------+...+-----------+...+-----------+
|        ENDPOINT        |        ID        | VERSION |...| IS LEADER |...| RAFT TERM |
+------------------------+------------------+---------+...+-----------+...+-----------+
| https://10.0.1.10:2379 | 22ea434a682f6cd4 |   3.6.6 |...|     false |...|         3 |
| https://10.0.1.11:2379 | 7c9f8e28614393e6 |   3.6.6 |...|      true |...|         3 |
| https://10.0.1.12:2379 | a1a46f140de895d1 |   3.6.6 |...|     false |...|         3 |
+------------------------+------------------+---------+...+-----------+...+-----------+
```

CP-0 is now a **follower**. The leadership does not return to the old leader automatically. This is correct raft behavior -- leadership only changes on election, and there's no reason to trigger one when a follower joins.

## Summary

| Step | Command | What happens |
|------|---------|--------------|
| Identify | `make show-etcd-status` | Find current leader (IS LEADER = true) |
| Kill | `make test-kill-node-cp N=0` | Leader powered off, triggers election |
| Observe | `make show-etcd-status` | New leader, raft term incremented |
| Verify | `kubectl get nodes`, deploy test pod | API works, cluster fully operational |
| Recover | `make test-recover-node-cp N=0` | Old leader rejoins as follower |
| Verify | `make show-etcd-status` | 3 members healthy, old leader is follower |

## Key learnings

1. **Leader election is fast** (seconds). The API is briefly unavailable during election but the LB retries mask this.
2. **The init node (CP-0) is not special** after bootstrap. Kill it and everything keeps working.
3. **Leadership doesn't auto-return** to the recovered node. It stays as follower until the next election event.
4. **No manual intervention needed** -- unlike test case 1, no etcd member removal or terraform replace required. Just power on and it rejoins.
5. **Raft term tracks elections** -- each election increments the term. Useful for understanding cluster history.
