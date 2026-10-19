output "server_public_ips" {
  description = "Public IPv4 addresses for each server (name -> list of IPs)."
  value = {
    "k8s-master" = binarylane_server.control_plane.public_ipv4_addresses
    "k8s-worker" = binarylane_server.worker.public_ipv4_addresses
  }
}
