terraform {
  required_version = ">= 1.5"

  required_providers {
    binarylane = {
      source  = "oscarhermoso/binarylane"
      version = "~> 0.13"
    }
  }
}

provider "binarylane" {
  # The API token is read automatically from the BINARYLANE_API_TOKEN env var.
  # Your src/.env now stores it as BINARYLANE_API_TOKEN, so export it (or source
  # the file) before running any terraform command that talks to the API:
  #
  #   export BINARYLANE_API_TOKEN="$(grep '^BINARYLANE_API_TOKEN=' ../src/.env | cut -d= -f2-)"
}

resource "binarylane_server" "control_plane" {
  name   = "k8s-master"
  image  = var.image
  region = var.region
  size   = var.size

  public_ipv4_count = 1
  password          = var.root_password
  backups           = false

  # cloud-init: install k3s as the control-plane (server) node.
  user_data = templatefile("${path.module}/templates/control-plane.yaml.tftpl", {
    k3s_token = var.k3s_token
  })
}

resource "binarylane_server" "worker" {
  name   = "k8s-worker"
  image  = var.image
  region = var.region
  size   = var.size

  public_ipv4_count = 1
  password          = var.root_password
  backups           = false

  # cloud-init: wait for the control plane, then join as a k3s agent.
  # Referencing the control plane's public IP also makes Terraform create it first.
  user_data = templatefile("${path.module}/templates/worker.yaml.tftpl", {
    k3s_token = var.k3s_token
    master_ip = binarylane_server.control_plane.public_ipv4_addresses[0]
  })
}
