# --- Private Network ---

resource "hcloud_network" "k8s" {
  name     = "${var.cluster_name}-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.k8s.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# --- Firewall ---

resource "hcloud_firewall" "k8s" {
  name = "${var.cluster_name}-fw"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = length(var.ssh_allowed_ips) > 0 ? var.ssh_allowed_ips : ["0.0.0.0/0", "::/0"]
  }

  # Kubernetes API
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = length(var.ssh_allowed_ips) > 0 ? var.ssh_allowed_ips : ["0.0.0.0/0", "::/0"]
  }

  # HTTP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # NodePort range (for ingress controllers)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "30000-32767"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Internal TCP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.0.1.0/24"]
  }

  # Internal UDP
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.0.1.0/24"]
  }
}

# --- Load Balancer ---

resource "hcloud_load_balancer" "k8s" {
  name               = "${var.cluster_name}-lb"
  load_balancer_type = "lb11"
  location           = var.locations[0]
  algorithm {
    type = "round_robin"
  }
}

resource "hcloud_load_balancer_network" "k8s" {
  load_balancer_id = hcloud_load_balancer.k8s.id
  network_id       = hcloud_network.k8s.id
}

# LB targets: control plane nodes (for API server)
resource "hcloud_load_balancer_target" "control_plane" {
  count            = var.control_plane_count
  load_balancer_id = hcloud_load_balancer.k8s.id
  type             = "server"
  server_id        = hcloud_server.control_plane[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.k8s, hcloud_server_network.control_plane]
}

# LB targets: workers (for ingress)
resource "hcloud_load_balancer_target" "worker" {
  count            = var.worker_count
  load_balancer_id = hcloud_load_balancer.k8s.id
  type             = "server"
  server_id        = hcloud_server.worker[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.k8s, hcloud_server_network.worker]
}

# LB service: Kubernetes API
resource "hcloud_load_balancer_service" "k8s_api" {
  load_balancer_id = hcloud_load_balancer.k8s.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# LB service: HTTP
resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.k8s.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# LB service: HTTPS
resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.k8s.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
