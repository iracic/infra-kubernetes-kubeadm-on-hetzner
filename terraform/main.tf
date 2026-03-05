# --- SSH Key ---

resource "hcloud_ssh_key" "default" {
  name       = var.ssh_key_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# --- Control Plane Nodes ---

resource "hcloud_server" "control_plane" {
  count       = var.control_plane_count
  name        = "${var.cluster_name}-cp-${count.index}"
  server_type = var.server_type
  image       = var.image
  location    = var.locations[count.index % length(var.locations)]
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    role     = "control-plane"
    cluster  = var.cluster_name
    location = var.locations[count.index % length(var.locations)]
  }

  firewall_ids = [hcloud_firewall.k8s.id]
}

resource "hcloud_server_network" "control_plane" {
  count      = var.control_plane_count
  server_id  = hcloud_server.control_plane[count.index].id
  network_id = hcloud_network.k8s.id
  ip         = "10.0.1.${10 + count.index}"
}

# --- Worker Nodes ---

resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = "${var.cluster_name}-worker-${count.index}"
  server_type = var.server_type
  image       = var.image
  location    = var.locations[count.index % length(var.locations)]
  ssh_keys    = [hcloud_ssh_key.default.id]

  labels = {
    role     = "worker"
    cluster  = var.cluster_name
    location = var.locations[count.index % length(var.locations)]
  }

  firewall_ids = [hcloud_firewall.k8s.id]
}

resource "hcloud_server_network" "worker" {
  count      = var.worker_count
  server_id  = hcloud_server.worker[count.index].id
  network_id = hcloud_network.k8s.id
  ip         = "10.0.1.${20 + count.index}"
}
