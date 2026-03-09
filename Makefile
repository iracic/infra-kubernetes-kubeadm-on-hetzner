TERRAFORM_DIR = terraform
ANSIBLE_DIR = ansible
KUBECONFIG_FILE = kubeconfig.yaml
N ?= 0
V ?=
AUTO_APPROVE ?=
DEBUG ?=
ANSIBLE_ARGS = $(if $(V),-$(V),)
TF_AUTO_APPROVE = $(if $(AUTO_APPROVE),-auto-approve,)
SSH_OPTS = -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes

.PHONY: all help prereqs infra-init infra-plan infra-apply inventory bootstrap cluster common cp workers kubeconfig cluster-info smoke-test status show-events show-etcd-status show-etcd-logs etcd-remove-member ssh-cp ssh-worker reset destroy clean-keys test-kill-cp test-kill-etcd test-kill-node-cp test-recover test-recover-node-cp test-deploy test-cleanup test-kill-node-worker test-recover-node-worker

all: infra-init infra-apply inventory bootstrap cluster kubeconfig smoke-test ## Full deploy from zero to working cluster

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Prerequisites ---

prereqs: ## Install local prerequisites (ansible, terraform, kubectl, jq)
	@echo "=== Installing prerequisites ==="
	@which pipx > /dev/null 2>&1 || (echo "Installing pipx..." && sudo apt install -y pipx)
	@which ansible-playbook > /dev/null 2>&1 || (echo "Installing ansible via pipx..." && pipx install --force ansible --include-deps)
	@which terraform > /dev/null 2>&1 || (echo "Installing terraform..." && sudo apt install -y gnupg software-properties-common && \
		wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null && \
		echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list && \
		sudo apt update && sudo apt install -y terraform)
	@which kubectl > /dev/null 2>&1 || (echo "Installing kubectl..." && \
		curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
		echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list && \
		sudo apt update && sudo apt install -y kubectl)
	@which jq > /dev/null 2>&1 || (echo "Installing jq..." && sudo apt install -y jq)
	@which hcloud > /dev/null 2>&1 || (echo "Installing hcloud CLI..." && sudo apt install -y hcloud-cli)
	@echo ""
	@echo "=== Versions ==="
	@terraform version | head -1
	@ansible --version | head -1
	@kubectl version --client --short 2>/dev/null || kubectl version --client | head -1
	@jq --version
	@hcloud version
	@echo ""
	@echo "All prerequisites installed."

# --- Infrastructure ---

infra-init: ## Initialize Terraform
	cd $(TERRAFORM_DIR) && terraform init

infra-plan: ## Plan infrastructure changes
	cd $(TERRAFORM_DIR) && terraform plan

infra-apply: ## Create/update infrastructure
	cd $(TERRAFORM_DIR) && terraform apply $(TF_AUTO_APPROVE)

inventory: ## Generate Ansible inventory from Terraform
	cd $(TERRAFORM_DIR) && terraform output -raw ansible_inventory > ../$(ANSIBLE_DIR)/inventory.ini
	@echo "Inventory written to $(ANSIBLE_DIR)/inventory.ini"
	@cat $(ANSIBLE_DIR)/inventory.ini

# --- Bootstrap ---

bootstrap: ## Create kadmin user (run once after infra-apply)
	@NEEDS=$$(cd $(ANSIBLE_DIR) && ansible k8s -m ping -e ansible_user=root --one-line 2>&1 | grep SUCCESS | awk '{print $$1}' | tr '\n' ',' | sed 's/,$$//'); \
	if [ -n "$$NEEDS" ]; then \
		echo "Bootstrapping: $$NEEDS"; \
		cd $(ANSIBLE_DIR) && ansible-playbook playbooks/bootstrap.yml --limit "$$NEEDS" $(ANSIBLE_ARGS); \
	else \
		echo "All nodes already bootstrapped (root SSH disabled)."; \
	fi

# --- Cluster Setup ---

cluster: common cp workers ## Full cluster setup (common + cp + workers)

common: ## Prepare all nodes (OS, containerd, kubeadm)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/common.yml $(ANSIBLE_ARGS)

cp: ## Initialize control plane + Calico
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/control-plane.yml $(ANSIBLE_ARGS)

workers: ## Join worker nodes
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/workers.yml $(ANSIBLE_ARGS)

# --- HA Tests (requires control_plane_count = 3) ---

test-kill-etcd: ## Stop etcd on CP N (default N=1), verify cluster still works. DEBUG=1 for details.
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	echo "=== Stopping etcd on CP-$(N) ($$CP_IP) ==="; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
	fi; \
	ssh $(SSH_OPTS) kadmin@$$CP_IP \
		"sudo crictl stop \$$(sudo crictl ps -q --name etcd) 2>/dev/null" ; \
	echo ""; \
	echo "=== Waiting 5s for cluster to react ==="; \
	sleep 5; \
	echo ""; \
	echo "=== Cluster status (should still work with 2/3 etcd) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n kube-system -l component=etcd -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members AFTER ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
		echo "--- kubelet logs on CP-$(N) ---"; \
		ssh $(SSH_OPTS) kadmin@$$CP_IP "sudo journalctl -u kubelet -n 10 --no-pager" 2>/dev/null; \
	fi; \
	echo ""; \
	echo "Recover with: make test-recover N=$(N)"

test-kill-cp: ## Stop kubelet on CP N (default N=1), verify cluster still works. DEBUG=1 for details.
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	echo "=== Stopping kubelet on CP-$(N) ($$CP_IP) ==="; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- Node status BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
		echo ""; \
	fi; \
	ssh $(SSH_OPTS) kadmin@$$CP_IP \
		"sudo systemctl stop kubelet" ; \
	echo ""; \
	echo "=== Waiting 10s for cluster to react ==="; \
	sleep 10; \
	echo ""; \
	echo "=== Cluster status (should still work via LB) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
		echo "--- Events (last 5) ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get events -n default --sort-by='.lastTimestamp' | tail -5; \
	fi; \
	echo ""; \
	echo "Recover with: make test-recover N=$(N)"

test-recover: ## Restart kubelet on CP N (default N=1). DEBUG=1 for details.
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	echo "=== Restarting kubelet on CP-$(N) ($$CP_IP) ==="; \
	ssh $(SSH_OPTS) kadmin@$$CP_IP \
		"sudo systemctl restart kubelet" ; \
	echo ""; \
	echo "=== Waiting 15s for node to rejoin ==="; \
	sleep 15; \
	echo ""; \
	echo "=== Cluster status ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n kube-system -l component=etcd -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
		echo "--- kubelet logs on CP-$(N) ---"; \
		ssh $(SSH_OPTS) kadmin@$$CP_IP "sudo journalctl -u kubelet -n 10 --no-pager" 2>/dev/null; \
	fi

test-kill-node-cp: ## Power off CP N via Hetzner API (default N=1). Most realistic HA test.
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	SERVER_NAME=$$(hcloud server list -o noheader -o columns=name,ipv4 | grep "$$CP_IP" | awk '{print $$1}'); \
	echo "=== Powering off $$SERVER_NAME ($$CP_IP) via Hetzner API ==="; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- Cluster status BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
		echo ""; \
		echo "--- etcd members BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
	fi; \
	hcloud server poweroff $$SERVER_NAME; \
	echo ""; \
	echo "=== Waiting 15s for cluster to react ==="; \
	sleep 15; \
	echo ""; \
	echo "=== Cluster status (API should respond, node still shows Ready) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n kube-system -l component=etcd -o wide; \
	echo ""; \
	echo "=== Waiting 45s for Kubernetes to detect node failure (node-monitor-grace-period=40s) ==="; \
	sleep 45; \
	echo ""; \
	echo "=== Cluster status (node should now be NotReady) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
	fi; \
	echo ""; \
	echo "Recover with: make test-recover-node-cp N=$(N)"

test-recover-node-cp: ## Power on CP N via Hetzner API (default N=1).
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	SERVER_NAME=$$(hcloud server list -o noheader -o columns=name,ipv4 | grep "$$CP_IP" | awk '{print $$1}'); \
	echo "=== Powering on $$SERVER_NAME ($$CP_IP) via Hetzner API ==="; \
	hcloud server poweron $$SERVER_NAME; \
	echo ""; \
	echo "=== Waiting 30s for node to boot and rejoin ==="; \
	sleep 30; \
	echo ""; \
	echo "=== Cluster status ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n kube-system -l component=etcd -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- etcd members ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}') -- \
			etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key -w table 2>/dev/null; \
		echo ""; \
		echo "--- kubelet logs on CP-$(N) ---"; \
		ssh $(SSH_OPTS) kadmin@$$CP_IP "sudo journalctl -u kubelet -n 10 --no-pager" 2>/dev/null; \
	fi

# --- HA Tests: Worker Failure (test case 3) ---

test-deploy: ## Deploy test workload (nginx, 2 replicas + NodePort service)
	@echo "=== Deploying test workload ==="
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl create deployment test-nginx --image=nginx:stable-alpine --replicas=2 2>/dev/null || \
		echo "Deployment already exists"
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl expose deployment test-nginx --type=NodePort --port=80 2>/dev/null || \
		echo "Service already exists"
	@echo ""
	@echo "=== Waiting for pods to be ready ==="
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl rollout status deployment/test-nginx --timeout=60s
	@echo ""
	@echo "=== Pod placement ==="
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -l app=test-nginx -o wide
	@echo ""
	@NODE_PORT=$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get svc test-nginx -o jsonpath='{.spec.ports[0].nodePort}'); \
	WORKER_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[0]'); \
	echo "=== Test access ==="; \
	echo "  curl -s http://$$WORKER_IP:$$NODE_PORT | head -5"; \
	echo ""; \
	curl -s --connect-timeout 5 http://$$WORKER_IP:$$NODE_PORT | head -5; \
	echo ""

test-cleanup: ## Remove test workload
	@echo "=== Removing test workload ==="
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl delete deployment test-nginx 2>/dev/null || echo "Deployment not found"
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl delete service test-nginx 2>/dev/null || echo "Service not found"
	@echo "Done."

test-kill-node-worker: ## Power off worker N via Hetzner API (default N=0). DEBUG=1 for details.
	@WORKER_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[$(N)]'); \
	SERVER_NAME=$$(hcloud server list -o noheader -o columns=name,ipv4 | grep "$$WORKER_IP" | awk '{print $$1}'); \
	echo "=== Powering off $$SERVER_NAME ($$WORKER_IP) via Hetzner API ==="; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- Pod placement BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -l app=test-nginx -o wide; \
		echo ""; \
		echo "--- Node status BEFORE ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
		echo ""; \
	fi; \
	hcloud server poweroff $$SERVER_NAME; \
	echo ""; \
	echo "=== Waiting 15s for cluster to react ==="; \
	sleep 15; \
	echo ""; \
	echo "=== Cluster status (node may still show Ready briefly) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	echo "=== Waiting 45s for Kubernetes to detect node failure (node-monitor-grace-period=40s) ==="; \
	sleep 45; \
	echo ""; \
	echo "=== Cluster status (node should now be NotReady) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	echo "=== Pod status (pods on dead node enter Terminating after ~5min) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -l app=test-nginx -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- Events ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get events --sort-by='.lastTimestamp' | grep -i 'nginx\|worker\|NotReady\|taint' | tail -10; \
	fi; \
	echo ""; \
	echo "Note: Pod eviction takes ~5 minutes (pod-eviction-timeout)."; \
	echo "      Watch with: KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -l app=test-nginx -o wide -w"; \
	echo ""; \
	echo "Recover with: make test-recover-node-worker N=$(N)"

test-recover-node-worker: ## Power on worker N via Hetzner API (default N=0). DEBUG=1 for details.
	@WORKER_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[$(N)]'); \
	SERVER_NAME=$$(hcloud server list -o noheader -o columns=name,ipv4 | grep "$$WORKER_IP" | awk '{print $$1}'); \
	echo "=== Powering on $$SERVER_NAME ($$WORKER_IP) via Hetzner API ==="; \
	hcloud server poweron $$SERVER_NAME; \
	echo ""; \
	echo "=== Waiting 30s for node to boot and rejoin ==="; \
	sleep 30; \
	echo ""; \
	echo "=== Cluster status ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide; \
	echo ""; \
	echo "=== Pod placement (k8s does NOT auto-rebalance pods) ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -l app=test-nginx -o wide; \
	if [ -n "$(DEBUG)" ]; then \
		echo ""; \
		echo "--- Events ---"; \
		KUBECONFIG=$(KUBECONFIG_FILE) kubectl get events --sort-by='.lastTimestamp' | grep -i 'nginx\|worker\|Ready' | tail -10; \
	fi; \
	echo ""; \
	echo "Note: Pods stay on worker-1. Kubernetes does not auto-rebalance."; \
	echo "Cleanup with: make test-cleanup"

# --- Reset ---

reset: ## Reset kubeadm on all nodes (keeps servers, destroys cluster)
	@echo "WARNING: This will reset kubeadm on ALL nodes."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	cd $(ANSIBLE_DIR) && ansible --become -m shell -a "kubeadm reset -f && rm -rf /etc/kubernetes /root/.kube /home/kadmin/.kube /var/lib/etcd /etc/cni/net.d /var/lib/calico && ip link delete cali+ 2>/dev/null; ip link delete tunl0 2>/dev/null; systemctl restart containerd && systemctl restart kubelet; true" k8s $(ANSIBLE_ARGS)

# --- Operations ---

kubeconfig: ## Fetch kubeconfig to local machine
	./scripts/fetch-kubeconfig.sh

cluster-info: ## Show cluster connection info and quick status
	@echo "=== Cluster Info ==="
	@echo ""
	@echo "KUBECONFIG=$(CURDIR)/$(KUBECONFIG_FILE)"
	@echo ""
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide
	@echo ""
	@echo "Load Balancer: $$(cd $(TERRAFORM_DIR) && terraform output -raw load_balancer_ip)"
	@echo "API Server:    https://$$(cd $(TERRAFORM_DIR) && terraform output -raw load_balancer_ip):6443"
	@echo ""
	@echo "Usage:"
	@echo "  export KUBECONFIG=$(CURDIR)/$(KUBECONFIG_FILE)"
	@echo "  kubectl get nodes"

smoke-test: ## Verify cluster health
	./scripts/smoke-test.sh

status: ## Show cluster status (nodes + all pods)
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide
	@echo ""
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -A

show-events: ## Show recent cluster events (filtered)
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get events -A --sort-by='.lastTimestamp' | grep -v 'some nameservers have been omitted' | tail -20

etcd-remove-member: ## Remove etcd member for CP N (default N=1). Use when node is permanently lost.
	@INTERNAL_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips_internal | jq -r '.[$(N)]'); \
	FIRST_CP=$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}'); \
	MEMBER_ID=$$(KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$FIRST_CP -- \
		etcdctl member list --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key 2>/dev/null \
		| grep "$$INTERNAL_IP" | cut -d',' -f1); \
	if [ -z "$$MEMBER_ID" ]; then \
		echo "No etcd member found for $$INTERNAL_IP"; \
		exit 1; \
	fi; \
	echo "=== Removing etcd member $$MEMBER_ID ($$INTERNAL_IP) from cluster ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl exec -n kube-system etcd-$$FIRST_CP -- \
		etcdctl member remove $$MEMBER_ID \
		--cacert /etc/kubernetes/pki/etcd/ca.crt \
		--cert /etc/kubernetes/pki/etcd/server.crt \
		--key /etc/kubernetes/pki/etcd/server.key; \
	echo ""; \
	echo "=== Deleting node from Kubernetes ==="; \
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl delete node $$(cd $(TERRAFORM_DIR) && terraform output -raw cluster_name 2>/dev/null || echo "k8s-lab")-cp-$(N) 2>/dev/null || true; \
	echo ""; \
	echo "Done. Now recreate the server:"; \
	echo "  cd terraform && terraform apply -replace='hcloud_server.control_plane[$(N)]' -replace='hcloud_server_network.control_plane[$(N)]' && cd .."; \
	echo "  make inventory && make bootstrap && make common && make cp"

show-etcd-status: ## Show etcd endpoint status (via SSH to CP N, default N=0)
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	echo "=== etcd status via CP-$(N) ($$CP_IP) ==="; \
	ssh $(SSH_OPTS) kadmin@$$CP_IP \
		"sudo crictl exec \$$(sudo crictl ps -q --name etcd) \
		etcdctl endpoint status --cluster -w table \
		--cacert /etc/kubernetes/pki/etcd/ca.crt \
		--cert /etc/kubernetes/pki/etcd/server.crt \
		--key /etc/kubernetes/pki/etcd/server.key \
		--command-timeout=2s" 2>&1; true

show-etcd-logs: ## Show etcd warnings/errors on CP N (default N=0)
	@CP_IP=$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]'); \
	echo "=== etcd logs on CP-$(N) ($$CP_IP) ==="; \
	ssh $(SSH_OPTS) kadmin@$$CP_IP \
		"sudo crictl logs \$$(sudo crictl ps -q --name etcd) 2>&1 | grep -i 'unreachable\|lost\|unhealthy\|timeout\|elected\|leader' | tail -20"

ssh-cp: ## SSH into control plane N (default N=0)
	@ssh $(SSH_OPTS) kadmin@$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]')

ssh-worker: ## SSH into worker N (default N=0)
	@ssh $(SSH_OPTS) kadmin@$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[$(N)]')

clean-keys: ## Remove cluster IPs from ~/.ssh/known_hosts
	@for ip in $$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips 2>/dev/null | jq -r '.[]') \
	            $$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips 2>/dev/null | jq -r '.[]') \
	            $$(cd $(TERRAFORM_DIR) && terraform output -raw load_balancer_ip 2>/dev/null); do \
		[ -n "$$ip" ] && ssh-keygen -R "$$ip" 2>/dev/null; \
	done
	@echo "SSH known_hosts cleaned."

destroy: ## Destroy all infrastructure (with confirmation)
	@if [ -z "$(AUTO_APPROVE)" ]; then \
		echo "WARNING: This will destroy ALL infrastructure."; \
		read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1); \
	fi
	@$(MAKE) clean-keys
	cd $(TERRAFORM_DIR) && terraform destroy $(TF_AUTO_APPROVE)
