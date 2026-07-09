# ------------------------------------------------------------
# Terraform and Provider Definition
# ------------------------------------------------------------

terraform {

  # Specify the minimum Terraform CLI version required to use this configuration.
  required_version = ">= 1.8"

  # Define the providers required by this configuration.
  required_providers {

    # Proxmox Virtual Environment provider.
    proxmox = {

      # Provider source address in the Terraform Registry.
      source = "bpg/proxmox"

      # Allow compatible provider versions within the 0.111 release series.
      version = "~> 0.111"
    }
  }
}