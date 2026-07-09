# ------------------------------------------------------------
# Provider Configuration
# ------------------------------------------------------------

# Configure the Proxmox provider used by Terraform.
provider "proxmox" {
  endpoint  = var.proxmox_api_endpoint
  api_token = var.proxmox_api_token
  insecure  = true

  ssh {
    agent       = false
    username    = var.proxmox_root_user
    private_key = file(var.proxmox_ssh_key_path)

    node {
      name    = var.proxmox_node_name
      address = var.proxmox_ssh_endpoint
      port    = var.proxmox_ssh_port
    }
  }
}