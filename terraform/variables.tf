variable "region" {
  description = "BinaryLane region slug (syd, mel, bne, adl, per, sin)."
  type        = string
  default     = "syd"
}

variable "image" {
  description = "Operating system image slug."
  type        = string
  default     = "ubuntu-24.04"
}

variable "size" {
  description = "Server size slug. 'std-min' = 1 vCPU / 1 GB RAM / 20 GB disk / 1 TB transfer ($4.90/mo)."
  type        = string
  default     = "std-min"
}

variable "root_password" {
  description = "Root password applied to both servers."
  type        = string
  sensitive   = true
}

variable "k3s_token" {
  description = "Shared secret token for the k3s cluster. Generate one with: openssl rand -hex 16"
  type        = string
  sensitive   = true
}
