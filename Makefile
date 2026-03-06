TERRAFORM_DIR = terraform
ANSIBLE_DIR = ansible
KUBECONFIG_FILE = kubeconfig.yaml
N ?= 0
V ?=
AUTO_APPROVE ?=
ANSIBLE_ARGS = $(if $(V),-$(V),)
TF_AUTO_APPROVE = $(if $(AUTO_APPROVE),-auto-approve,)

.PHONY: all help prereqs infra-init infra-plan infra-apply inventory bootstrap cluster common cp workers kubeconfig cluster-info smoke-test status ssh-cp ssh-worker reset destroy clean-keys

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
	@echo ""
	@echo "=== Versions ==="
	@terraform version | head -1
	@ansible --version | head -1
	@kubectl version --client --short 2>/dev/null || kubectl version --client | head -1
	@jq --version
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

# --- Reset ---

reset: ## Reset kubeadm on all nodes (keeps servers, destroys cluster)
	@echo "WARNING: This will reset kubeadm on ALL nodes."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	cd $(ANSIBLE_DIR) && ansible --become -m shell -a "kubeadm reset -f && rm -rf /etc/kubernetes /root/.kube /home/kadmin/.kube /var/lib/etcd /etc/cni/net.d /var/lib/calico && ip link delete cali+ 2>/dev/null; ip link delete tunl0 2>/dev/null; true" k8s $(ANSIBLE_ARGS)

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

ssh-cp: ## SSH into control plane N (default N=0)
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes kadmin@$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]')

ssh-worker: ## SSH into worker N (default N=0)
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes kadmin@$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[$(N)]')

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
