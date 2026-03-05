output "control_plane_ips" {
  description = "Public IPs of control plane nodes"
  value       = hcloud_server.control_plane[*].ipv4_address
}

output "control_plane_ip" {
  description = "Public IP of first control plane node"
  value       = hcloud_server.control_plane[0].ipv4_address
}

output "control_plane_ips_internal" {
  description = "Internal IPs of control plane nodes"
  value       = hcloud_server_network.control_plane[*].ip
}

output "worker_ips" {
  description = "Public IPs of worker nodes"
  value       = hcloud_server.worker[*].ipv4_address
}

output "worker_ips_internal" {
  description = "Internal IPs of worker nodes"
  value       = hcloud_server_network.worker[*].ip
}

output "load_balancer_ip" {
  description = "Public IP of load balancer"
  value       = hcloud_load_balancer.k8s.ipv4
}

output "ansible_inventory" {
  description = "Generated Ansible inventory"
  value = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    control_planes = [
      for i, cp in hcloud_server.control_plane : {
        name        = cp.name
        public_ip   = cp.ipv4_address
        internal_ip = hcloud_server_network.control_plane[i].ip
      }
    ]
    workers = [
      for i, w in hcloud_server.worker : {
        name        = w.name
        public_ip   = w.ipv4_address
        internal_ip = hcloud_server_network.worker[i].ip
      }
    ]
    lb_ip       = hcloud_load_balancer.k8s.ipv4
    k8s_version = var.k8s_version
  })
}
