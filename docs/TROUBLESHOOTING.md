# Troubleshooting

## Common issues on Hetzner + kubeadm

### Calico pods stuck in Init/CrashLoopBackOff

Missing kernel modules. SSH into the node and run:

```bash
modprobe ipip
modprobe ip_tunnel
modprobe overlay
modprobe br_netfilter
systemctl restart kubelet
```

### Nodes show NotReady

Usually Calico-related. Check Calico pods first:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
kubectl logs -n kube-system -l k8s-app=calico-node
```

### kubectl connection refused

The kubeconfig might point to wrong API server address. After fetching kubeconfig, verify:

```bash
grep server kubeconfig.yaml
# Should point to the load balancer IP, not internal IP
```

### Worker or CP node can't join: token/certificate expired

kubeadm tokens expire after 24h, certificate keys after 2h. Regenerate:

```bash
# On first control plane node
kubeadm token create --print-join-command > /root/join-command.txt

# For additional CP nodes, also re-upload certs:
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
echo "$(cat /root/join-command.txt) --control-plane --certificate-key $CERT_KEY" > /root/cp-join-command.txt
```

Then re-run `make cp` or `make workers`.

### Scaling control plane (1 to 3 or 3 to 1)

**1 to 3:** Change `control_plane_count = 3` in terraform.tfvars, then:
```bash
make infra-apply
make inventory
make common         # prepare new nodes
make cp             # join new CP nodes (first CP is skipped, already initialized)
```

**3 to 1 (proper scale-down):**

You must respect etcd quorum. With 3 members, quorum is 2. Remove nodes **one at a time**.

```bash
# 1. Drain and remove CP-2
kubectl drain k8s-lab-cp-2 --delete-emptydir-data --ignore-daemonsets
ssh kadmin@<cp-2-ip> "sudo kubeadm reset -f"
kubectl delete node k8s-lab-cp-2

# 2. Drain and remove CP-1 (now quorum is 1/1, safe)
kubectl drain k8s-lab-cp-1 --delete-emptydir-data --ignore-daemonsets
ssh kadmin@<cp-1-ip> "sudo kubeadm reset -f"
kubectl delete node k8s-lab-cp-1

# 3. Update terraform and destroy extra servers
# Edit terraform.tfvars: control_plane_count = 1
make infra-apply
make inventory
```

Etcd quorum reference:

| CP nodes | Quorum | Max failures |
|----------|--------|--------------|
| 1        | 1      | 0            |
| 2        | 2      | 0 (worse than 1 or 3!) |
| 3        | 2      | 1            |

**Never** remove 2 nodes at once from a 3-node etcd cluster -- you lose quorum and the API server stops responding. If you already lost quorum, the only recovery is a full reset:

```bash
make reset
# Edit terraform.tfvars: control_plane_count = 1
make destroy AUTO_APPROVE=1
make all
```

### Replacing a failed control plane node

When a CP node is permanently lost (hardware failure, corrupted disk), you need to remove it from the cluster and create a fresh replacement.

```bash
# 1. Remove the etcd member from a healthy CP node
#    List members to find the ID of the failed node:
kubectl exec -n kube-system etcd-k8s-lab-cp-0 -- etcdctl member list \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key

#    Remove the failed member by ID:
kubectl exec -n kube-system etcd-k8s-lab-cp-0 -- etcdctl member remove <MEMBER_ID> \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key

# 2. Delete the node from Kubernetes
kubectl delete node k8s-lab-cp-1

# 3. Recreate the server (-replace forces destroy + create)
cd terraform
terraform apply -replace='hcloud_server.control_plane[1]' -replace='hcloud_server_network.control_plane[1]'

# 4. Join the new server to the cluster
make inventory
make bootstrap       # bootstrap the new node
make common          # install containerd, kubeadm
make cp              # join as new CP (existing CPs are skipped)
```

The new node gets the same IP (assigned statically in terraform) and joins as a fresh etcd member.

### containerd issues

If pods fail to start with containerd errors:

```bash
# On the affected node
systemctl restart containerd
systemctl restart kubelet
```

If that doesn't help, regenerate containerd config:

```bash
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl restart kubelet
```

### Load balancer health checks failing

The LB has three services: API (6443), HTTP (80), HTTPS (443). Health checks on ports 80 and 443 will show as unhealthy until you deploy an ingress controller - this is expected and does not affect the API server.

Verify the API server is reachable from within the private network:

```bash
# From any node
curl -k https://10.0.1.10:6443/healthz
```

Check that LB targets use private IPs (configured in Terraform).

### MTU issues (packet drops, timeouts between pods)

Calico auto-detects the correct MTU from the underlying network interface. On Hetzner, the private network interface (`enp7s0`) has MTU 1450, and Calico sets veth MTU to 1430 (1450 minus 20 bytes IPIP overhead). No manual configuration needed.

Verify:

```bash
# On any node
cat /sys/class/net/cali*/mtu
# Should be 1430 (auto-detected)
```
