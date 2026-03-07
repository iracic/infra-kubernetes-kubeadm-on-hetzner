# Kubernetes HA with kubeadm on Hetzner Cloud

If you want to understand how Kubernetes HA actually works under the hood - etcd consensus, control plane redundancy, certificate management - there's no better way than building it yourself. Cloud-managed Kubernetes (EKS, GKE, OVH Managed K8s) hides all of this from you, which is great for production but bad for learning.

This guide uses Hetzner Cloud because it's the cheapest way to spin up multiple servers in Europe (~4 EUR/node/month). **This is a learning project, not a production architecture recommendation.** For production, consider managed Kubernetes (EKS, GKE, OVH) where the control plane is handled for you. That said, Hetzner is a solid and cost-effective platform for teams comfortable with self-managed infrastructure.

What you'll learn:
- How etcd quorum works and why it matters
- kubeadm certificate management and multi-CP join
- Calico CNI networking on a private network
- Load balancer in front of multiple API servers

Total cost: ~20 EUR/month for a 3 CP + 1 worker cluster. Total deploy time: ~8 minutes.

**Stack:** Terraform + Ansible + kubeadm + Calico CNI

## Architecture

```
                         Internet
                            |
                   +--------+--------+
                   | Hetzner Load    |
                   | Balancer (lb11) |
                   +--------+--------+
                            |
          Private Network 10.0.1.0/24 (eu-central zone)
     +----------+-----------+-----------+----------+
     |          |           |           |          |
+----+----+----+----+ +----+----+ +----+----+----+----+
| CP-0    | CP-1    | | CP-2    | | Worker 0| |Worker N|
|10.0.1.10|10.0.1.11| |10.0.1.12| |10.0.1.20| |10.0.1.x|
| fsn1    | nbg1    | | hel1    | | fsn1    | | ...    |
+---------+---------+ +---------+ +---------+---------+

  Nodes distributed round-robin across locations
  control_plane_count = 3 (HA) or 1 (single)
  Pod Network (Calico): 10.244.0.0/16
  Service Network:      10.96.0.0/12
```

### Network topology

| Component         | IP / Range       | Notes                              |
|-------------------|------------------|------------------------------------|
| Private network   | 10.0.0.0/16      | Hetzner vSwitch                    |
| Node subnet       | 10.0.1.0/24      | eu-central zone                    |
| Control planes    | 10.0.1.10-12     | 1 or 3 nodes (configurable)        |
| Workers           | 10.0.1.20+       | Sequential internal IPs            |
| Pod CIDR (Calico) | 10.244.0.0/16    | IPIP mode, auto-detect MTU        |
| Service CIDR      | 10.96.0.0/12     | Default kubeadm                    |
| Load balancer     | public IP        | API (6443), HTTP (80), HTTPS (443) |

### Hetzner-specific considerations

- **Kernel modules** `ipip`, `ip_tunnel` required for Calico IPIP tunnels
- **Load balancer targets** must use private IPs (`use_private_ip = true`)
- **kubelet `--node-ip`** must be set to internal IP (otherwise uses public IP)

## Prerequisites

Local machine requirements:

```bash
# Terraform >= 1.5
terraform version

# Ansible >= 2.15 (see install options below)
ansible --version

# kubectl
kubectl version --client

# jq (used by Makefile for SSH targets)
jq --version

# SSH key pair (will be uploaded to Hetzner)
ls ~/.ssh/id_ed25519
```

### Installing Ansible

**pipx (recommended)** -- latest version, isolated, no venv activation needed:

```bash
sudo apt install pipx
pipx install ansible
```

Why pipx over alternatives:
- **apt** (`apt install ansible`) -- works but version tied to Ubuntu release cycle
- **snap** -- avoid: snap confinement blocks access to `~/.ssh/` and `/etc/`, which breaks Ansible
- **pip in venv** -- works but requires `source activate` every session
- **pipx** -- best of both worlds: isolated like venv, usable like apt

### Hetzner setup

1. Create a project in [Hetzner Cloud Console](https://console.hetzner.cloud/)
2. Go to Security > API Tokens > Generate API Token (read/write)
3. Copy the token into `terraform/terraform.tfvars`:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars and paste your token as hcloud_token
```

## Project structure

```
.
├── README.md
├── Makefile                          # Orchestration from local desktop
│
├── terraform/
│   ├── versions.tf                   # Provider versions and constraints
│   ├── variables.tf                  # Input variables
│   ├── main.tf                       # Server resources (CP + workers)
│   ├── network.tf                    # Network, subnet, firewall, LB
│   ├── outputs.tf                    # IPs, inventory for Ansible
│   ├── terraform.tfvars.example      # Example variable values
│   └── .gitignore
│
├── ansible/
│   ├── ansible.cfg                   # Ansible configuration
│   ├── inventory.ini                 # Generated by Terraform output
│   ├── playbooks/
│   │   ├── bootstrap.yml             # Create kadmin user, disable root SSH
│   │   ├── site.yml                  # Main playbook (runs all)
│   │   ├── common.yml                # OS prep, kernel modules, containerd
│   │   ├── control-plane.yml         # kubeadm init, Calico, join tokens
│   │   └── workers.yml               # kubeadm join
│   └── roles/
│       ├── bootstrap/                # kadmin user setup
│       │   └── tasks/main.yml
│       ├── common/                   # Shared OS config
│       │   └── tasks/main.yml
│       ├── containerd/               # Container runtime
│       │   └── tasks/main.yml
│       ├── kubernetes/               # kubeadm, kubelet, kubectl install
│       │   └── tasks/main.yml
│       ├── control-plane/            # kubeadm init (first CP)
│       │   ├── tasks/main.yml
│       │   └── templates/
│       │       └── kubeadm-config.yml.j2
│       ├── control-plane-join/       # kubeadm join --control-plane (CP 1,2)
│       │   └── tasks/main.yml
│       ├── calico/                   # Calico CNI + join command generation
│       │   └── tasks/main.yml
│       └── worker/                   # kubeadm join (workers)
│           └── tasks/main.yml
│
├── scripts/
│   ├── fetch-kubeconfig.sh           # Download kubeconfig to local machine
│   └── smoke-test.sh                 # Verify cluster health
│
└── docs/
    └── TROUBLESHOOTING.md            # Common issues and fixes
```

## Deployment flow

The entire flow is driven from local desktop via `make` targets:

### Phase 1: Infrastructure (Terraform)

```
make infra-init      # terraform init
make infra-plan      # terraform plan (review changes)
make infra-apply     # terraform apply (create servers, network, LB, firewall)
make inventory       # generate ansible/inventory.ini from terraform output
```

**What Terraform creates:**
1. SSH key (uploaded to Hetzner)
2. Private network + subnet (10.0.1.0/24)
3. Firewall rules (SSH, API, HTTP/S, internal traffic)
4. Control plane server(s) -- 1 or 3 (cx23, Ubuntu 24.04)
5. Worker server(s) (cx23, Ubuntu 24.04)
6. Load balancer (lb11) with targets
7. (Optional) Floating IP

Servers are created with **minimal cloud-init** -- just enough to allow SSH access. All Kubernetes configuration is done via Ansible.

### Phase 2: Cluster setup (Ansible)

```
make cluster         # run full ansible playbook (= make common + cp + workers)
```

Or step by step:

```
make common          # OS prep on all nodes (kernel modules, containerd, kubeadm)
make cp              # kubeadm init on control plane, install Calico
```

Add `V=` for verbose output (useful for debugging slow tasks):

```
make cluster V=v     # verbose
make cluster V=vv    # more verbose
make cp V=vvv        # maximum verbosity, single step
make workers         # kubeadm join on worker nodes
```

**Ansible playbook breakdown:**

#### `common.yml` -- all nodes
1. apt update + install prerequisites (apt-transport-https, curl, etc.)
2. Load kernel modules: `overlay`, `br_netfilter`, `ipip`, `ip_tunnel`
3. Persist kernel modules in `/etc/modules-load.d/k8s.conf`
4. Set sysctl params (ip_forward, bridge-nf-call-iptables)
5. Install and configure containerd (`SystemdCgroup = true`)
6. Add Kubernetes apt repository
7. Install kubeadm, kubelet, kubectl + hold versions
8. Configure kubelet `--node-ip` to internal IP

#### `control-plane.yml` -- control plane nodes
**First CP node (kubeadm init):**
1. Generate kubeadm config (template with correct IPs, SANs, CIDRs)
2. Run `kubeadm init --config kubeadm-config.yml`
3. Set up `/root/.kube/config`
4. Install Calico CNI (v3.31)
5. Wait for first CP node Ready
6. Generate worker join command + CP join command (with certificate key)
7. Upload certificates for additional CP nodes

**Additional CP nodes (kubeadm join --control-plane):**
8. Get CP join command from first node
9. Run `kubeadm join --control-plane --certificate-key <key>`
10. Wait for node Ready

Skipped automatically when `control_plane_count = 1`.

#### `workers.yml` -- worker nodes
1. Get join command from control plane (Ansible fact)
2. Run `kubeadm join`
3. Wait for node Ready

### Phase 3: Verification

```
make kubeconfig      # fetch kubeconfig to local machine
make smoke-test      # verify cluster health
make status          # kubectl get nodes + pods -A
```

### Day 2 operations

```
make ssh-cp          # SSH into first control plane (N=0)
make ssh-cp N=1      # SSH into second control plane
make ssh-worker N=1  # SSH into worker N
make reset           # reset kubeadm on all nodes (keeps servers)
make clean-keys      # remove cluster IPs from ~/.ssh/known_hosts
make destroy         # tear down everything (with confirmation)
make destroy AUTO_APPROVE=1  # skip confirmation + terraform -auto-approve
```

### Scaling control plane (1 to 3)

```bash
# Edit terraform/terraform.tfvars:  control_plane_count = 3
make infra-apply     # create new CP servers
make inventory       # regenerate inventory
make common          # prepare new nodes
make cp              # join new CP nodes (first CP skipped, already initialized)
```

### Scaling control plane (3 to 1)

You **cannot** just change terraform and re-apply. Etcd requires quorum (2/3 members). Removing 2 nodes at once kills the cluster.

**Option A: Proper scale-down** (no downtime)

Remove nodes one at a time. See `docs/TROUBLESHOOTING.md` for the full procedure.

**Option B: Full redeploy** (simpler, has downtime)

```bash
make reset
# Edit terraform/terraform.tfvars:  control_plane_count = 1
make destroy AUTO_APPROVE=1
make all
```

## Quick start

```bash
# 1. Clone and configure
git clone <this-repo>
cd infra-kubernetes-kubeadm-on-hetzner
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your HCLOUD_TOKEN and preferences

# 2. Install prerequisites
make prereqs

# 3. Deploy everything (infra + bootstrap + cluster + kubeconfig + smoke-test)
time make all
```

Terraform will ask for confirmation before creating infrastructure. To skip the prompt:

```bash
time make all AUTO_APPROVE=yes
```

To tear down and measure:

```bash
time make destroy
```

Or step by step:

```bash
make infra-init          # initialize Terraform
make infra-apply         # create infrastructure (asks for confirmation)
make inventory           # generate Ansible inventory
make bootstrap           # create kadmin user, disable root SSH
make cluster             # install Kubernetes (common + cp + workers)
make kubeconfig          # fetch kubeconfig + show cluster-info
make smoke-test          # verify everything is healthy
```

Total time: ~8 minutes from zero to working cluster.

### All make targets

```
make all             Full deploy from zero to working cluster
make prereqs         Install local prerequisites (ansible, terraform, kubectl, jq)

make infra-init      Initialize Terraform
make infra-plan      Plan infrastructure changes
make infra-apply     Create/update infrastructure
make inventory       Generate Ansible inventory from Terraform

make bootstrap       Create kadmin user, disable root SSH (run once)

make cluster         Full cluster setup (= common + cp + workers)
make common          Prepare all nodes (OS, containerd, kubeadm)
make cp              Initialize control plane + Calico
make workers         Join worker nodes

make kubeconfig      Fetch kubeconfig to local machine
make cluster-info    Show cluster connection info and quick status
make smoke-test      Verify cluster health
make status          Show nodes + all pods

make ssh-cp          SSH into control plane (N=0,1,2)
make ssh-worker      SSH into worker (N=0,1,...)
make clean-keys      Remove cluster IPs from ~/.ssh/known_hosts
make reset           Reset kubeadm on all nodes (keeps servers)
make destroy         Destroy all infrastructure (with confirmation)
```

`AUTO_APPROVE=1` works with `make all`, `make infra-apply`, and `make destroy`.

## Configuration

### Terraform variables

| Variable              | Default                 | Description                        |
|-----------------------|-------------------------|------------------------------------|
| `hcloud_token`        | -                       | Hetzner API token (required)       |
| `ssh_key_name`        | `k8s-admin`            | Name of SSH key in Hetzner         |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Path to local SSH public key      |
| `locations`           | `[fsn1, nbg1, hel1]`    | Nodes distributed round-robin     |
| `server_type`         | `cx23`                  | 2 vCPU, 4GB RAM, 40GB SSD         |
| `image`               | `ubuntu-24.04`          | OS image                           |
| `control_plane_count` | `3`                     | CP nodes: 1 (single) or 3 (HA)   |
| `worker_count`        | `1`                     | Number of worker nodes             |
| `k8s_version`         | `1.35`                  | Kubernetes minor version           |
| `cluster_name`        | `k8s-lab`               | Cluster name prefix                |

### Server sizing guide

| Type   | vCPU | RAM  | SSD   | Price/mo | Use case              |
|--------|------|------|-------|----------|-----------------------|
| cx22   | 2    | 4GB  | 40GB  | ~4 EUR   | Minimal test          |
| cx23   | 2    | 4GB  | 40GB  | ~4 EUR   | Default (this project)|
| cx32   | 4    | 8GB  | 80GB  | ~8 EUR   | Dev/staging           |
| cx42   | 8    | 16GB | 160GB | ~15 EUR  | Production workloads  |
| cax11  | 2    | 4GB  | 40GB  | ~4 EUR   | ARM64, cost-optimized |

## Firewall rules

| Port  | Protocol | Source        | Purpose                   |
|-------|----------|---------------|---------------------------|
| 22    | TCP      | your IP / any | SSH access                |
| 6443  | TCP      | your IP / any | Kubernetes API            |
| 80    | TCP      | any           | HTTP ingress              |
| 443   | TCP      | any           | HTTPS ingress             |
| all   | TCP/UDP  | 10.0.1.0/24   | Internal node traffic     |

## Security notes

- No root SSH -- `make bootstrap` creates `kadmin` user with sudo, disables root login
- SSH key-based auth only (password auth disabled)
- Firewall restricts access to necessary ports only
- API server accessible via load balancer (not directly on node public IP)
- Consider restricting SSH and API access to your IP only (`allowed_ips` variable)
- Secrets (tokens, certs) stay on the cluster, not in Terraform state
- `terraform.tfvars` is gitignored (contains sensitive token)

## Lessons learned

Baked into the Ansible roles based on real production experience:

1. **Calico MTU auto-detect** -- Calico correctly detects Hetzner's private network MTU (1450) and sets veth MTU to 1430 (minus IPIP overhead). No manual MTU configuration needed.
2. **kubelet --node-ip** -- Without this, kubelet advertises public IP, breaking internal routing
3. **LB private IP targets** -- Hetzner LB must target private IPs when using private network
4. **SystemdCgroup = true** -- containerd must use systemd cgroup driver to match kubelet
5. **ipip + ip_tunnel modules** -- Required for Calico IPIP mode, not loaded by default on Ubuntu 24.04
6. **Extra SANs on API cert** -- Must include LB IP, internal IP, and public IP
7. **Wait for readiness** -- Calico pods take 1-3 minutes to stabilize after install
