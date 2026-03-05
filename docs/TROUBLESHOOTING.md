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

**3 to 1:** Change `control_plane_count = 1` in terraform.tfvars, then:
```bash
# First, drain and remove extra CP nodes from the cluster
kubectl drain k8s-lab-cp-1 --delete-emptydir-data --ignore-daemonsets
kubectl delete node k8s-lab-cp-1
kubectl drain k8s-lab-cp-2 --delete-emptydir-data --ignore-daemonsets
kubectl delete node k8s-lab-cp-2

# Remove etcd members (from first CP)
# List members:
kubectl exec -n kube-system etcd-k8s-lab-cp-0 -- etcdctl member list \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key
# Remove each extra member by ID

# Then destroy extra servers
make infra-apply
make inventory
```

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

Calico veth MTU must be 1450 on Hetzner (not 1500). Verify:

```bash
# On any node
ip link show | grep cali
# MTU should be 1450
```

If wrong, edit the calico-config ConfigMap:

```bash
kubectl edit configmap calico-config -n kube-system
# Set veth_mtu: "1450"
kubectl rollout restart daemonset calico-node -n kube-system
```
