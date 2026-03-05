TERRAFORM_DIR = terraform
ANSIBLE_DIR = ansible
KUBECONFIG_FILE = kubeconfig.yaml
N ?= 0
V ?=
ANSIBLE_ARGS = $(if $(V),-$(V),)

.PHONY: help prereqs infra-init infra-plan infra-apply inventory cluster common cp workers kubeconfig smoke-test status ssh-cp ssh-worker destroy

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
		curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
		echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list && \
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
	cd $(TERRAFORM_DIR) && terraform apply

inventory: ## Generate Ansible inventory from Terraform
	cd $(TERRAFORM_DIR) && terraform output -raw ansible_inventory > ../$(ANSIBLE_DIR)/inventory.ini
	@echo "Inventory written to $(ANSIBLE_DIR)/inventory.ini"
	@cat $(ANSIBLE_DIR)/inventory.ini

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
	cd $(ANSIBLE_DIR) && ansible -m shell -a "kubeadm reset -f && rm -rf /etc/kubernetes /root/.kube /var/lib/etcd" k8s $(ANSIBLE_ARGS)

# --- Operations ---

kubeconfig: ## Fetch kubeconfig to local machine
	./scripts/fetch-kubeconfig.sh

smoke-test: ## Verify cluster health
	./scripts/smoke-test.sh

status: ## Show cluster status
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide
	@echo ""
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -A

ssh-cp: ## SSH into control plane N (default N=0)
	@ssh root@$$(cd $(TERRAFORM_DIR) && terraform output -json control_plane_ips | jq -r '.[$(N)]')

ssh-worker: ## SSH into worker N (default N=0)
	@ssh root@$$(cd $(TERRAFORM_DIR) && terraform output -json worker_ips | jq -r '.[$(N)]')

destroy: ## Destroy all infrastructure (with confirmation)
	@echo "WARNING: This will destroy ALL infrastructure."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	cd $(TERRAFORM_DIR) && terraform destroy
