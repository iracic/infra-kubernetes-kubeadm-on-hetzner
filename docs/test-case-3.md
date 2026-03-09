# Test Case 3: Worker Node Failure + Pod Rescheduling

Simulate a worker node failure, observe pod eviction and rescheduling, then recover.

Requires: `worker_count = 2`, `hcloud` CLI configured.

**What makes this different from previous test cases:**
- Test case 1: kill a CP follower, remove + replace permanently
- Test case 2: kill the etcd leader, observe election, recover
- Test case 3: kill a worker, observe pod eviction, recover (no replacement needed)

## 0. Deploy test workload

```bash
make test-deploy
```

Deploys nginx (2 replicas) with a NodePort service. One pod per worker:

```
=== Pod placement ===
NAME                          READY   STATUS    NODE
test-nginx-xxxxxxxxx-xxxxx   1/1     Running   k8s-lab-worker-0
test-nginx-xxxxxxxxx-xxxxx   1/1     Running   k8s-lab-worker-1
```

Verify the service works:

```bash
NODE_PORT=$(kubectl get svc test-nginx -o jsonpath='{.spec.ports[0].nodePort}')
WORKER_IP=$(cd terraform && terraform output -json worker_ips | jq -r '.[1]')
curl -s http://$WORKER_IP:$NODE_PORT | head -5
```

## 1. Kill the worker

```bash
make test-kill-node-worker N=0 DEBUG=1
```

Server is powered off via Hetzner API. After ~40s Kubernetes marks it as `NotReady`.

```
=== Powering off k8s-lab-worker-0 (x.x.x.x) via Hetzner API ===
Server 123456789 stopped
```

## 2. Observe the damage

```bash
kubectl get nodes
```

```
NAME               STATUS     ROLES           AGE   VERSION
k8s-lab-cp-0       Ready      control-plane   90m   v1.35.2
k8s-lab-cp-1       Ready      control-plane   88m   v1.35.2
k8s-lab-cp-2       Ready      control-plane   87m   v1.35.2
k8s-lab-worker-0   NotReady   <none>          86m   v1.35.2
k8s-lab-worker-1   Ready      <none>          86m   v1.35.2
```

### Pod eviction timeline

The pod on the dead node does NOT immediately reschedule. Kubernetes follows this timeline:

| Time | What happens |
|------|-------------|
| 0s | Worker powered off |
| ~40s | Node marked `NotReady` (node-monitor-grace-period) |
| ~5min | Pods on `NotReady` node get evicted (pod-eviction-timeout) |
| ~5min | New pod scheduled on surviving worker |

Watch it live:

```bash
KUBECONFIG=kubeconfig.yaml kubectl get pods -l app=test-nginx -o wide -w
```

After ~5 minutes:

```
NAME                          READY   STATUS        NODE
test-nginx-xxxxxxxxx-old      1/1     Terminating   k8s-lab-worker-0
test-nginx-xxxxxxxxx-xxxxx    1/1     Running       k8s-lab-worker-1
test-nginx-xxxxxxxxx-new      1/1     Running       k8s-lab-worker-1
```

Both replicas now run on `worker-1`. The `Terminating` pod stays in that state until the node comes back (kubelet needs to confirm deletion).

### Service continuity

The NodePort service continues to work through the surviving worker:

```bash
WORKER_IP=$(cd terraform && terraform output -json worker_ips | jq -r '.[1]')
curl -s http://$WORKER_IP:$NODE_PORT | head -5
```

This works because kube-proxy updates iptables rules to route only to healthy pod endpoints.

## 3. Recover the worker

```bash
make test-recover-node-worker N=0 DEBUG=1
```

```
=== Powering on k8s-lab-worker-0 (x.x.x.x) via Hetzner API ===
Server 123456789 started
```

After ~30s the node rejoins as `Ready`:

```
NAME               STATUS   ROLES           AGE   VERSION
k8s-lab-cp-0       Ready    control-plane   95m   v1.35.2
k8s-lab-cp-1       Ready    control-plane   93m   v1.35.2
k8s-lab-cp-2       Ready    control-plane   92m   v1.35.2
k8s-lab-worker-0   Ready    <none>          91m   v1.35.2
k8s-lab-worker-1   Ready    <none>          91m   v1.35.2
```

### Pods do NOT auto-rebalance

```bash
kubectl get pods -l app=test-nginx -o wide
```

```
NAME                          READY   STATUS    NODE
test-nginx-xxxxxxxxx-xxxxx    1/1     Running   k8s-lab-worker-1
test-nginx-xxxxxxxxx-new      1/1     Running   k8s-lab-worker-1
```

Both pods stay on `worker-1`. Kubernetes does not move running pods to balance load. The `Terminating` pod on `worker-0` gets cleaned up once the kubelet restarts.

To manually rebalance, delete a pod and let the scheduler place it:

```bash
kubectl delete pod <pod-name>
# New pod will likely land on worker-0 (less loaded)
```

## 4. Cleanup

```bash
make test-cleanup
```

## Summary

| Step | Command | What happens |
|------|---------|--------------|
| Deploy | `make test-deploy` | nginx (2 replicas) + NodePort, 1 pod per worker |
| Kill | `make test-kill-node-worker N=0` | Worker powered off, node goes NotReady |
| Wait | ~5 minutes | Pod evicted, rescheduled to surviving worker |
| Verify | `curl` NodePort on worker-1 | Service still works, both pods on worker-1 |
| Recover | `make test-recover-node-worker N=0` | Node rejoins, pods stay on worker-1 |
| Cleanup | `make test-cleanup` | Remove test deployment |

## Key learnings

1. **Pod eviction is slow by design** (~5 min). This prevents unnecessary rescheduling during brief network blips.
2. **Pods don't auto-rebalance** after node recovery. Use [Descheduler](https://github.com/kubernetes-sigs/descheduler) if this matters.
3. **Services route around failure** automatically via kube-proxy endpoint updates.
4. **No manual intervention needed** for worker recovery (unlike CP nodes which may need etcd cleanup).
