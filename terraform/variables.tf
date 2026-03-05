variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name for the SSH key in Hetzner"
  type        = string
  default     = "k8s-admin"
}

variable "ssh_public_key_path" {
  description = "Path to local SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "locations" {
  description = "Hetzner datacenter locations (nodes distributed round-robin)"
  type        = list(string)
  default     = ["fsn1", "nbg1", "hel1"]
}

variable "server_type" {
  description = "Hetzner server type for all nodes"
  type        = string
  default     = "cx23"
}

variable "image" {
  description = "OS image for servers"
  type        = string
  default     = "ubuntu-24.04"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (1 or 3 for HA)"
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "control_plane_count must be 1 or 3."
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.32)"
  type        = string
  default     = "1.32"
}

variable "cluster_name" {
  description = "Cluster name prefix for resources"
  type        = string
  default     = "k8s-lab"
}

variable "ssh_allowed_ips" {
  description = "List of IPs allowed to SSH (CIDR). Empty = allow all."
  type        = list(string)
  default     = []
}
