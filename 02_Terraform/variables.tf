# ------------------------------------------------------------
# Variable Definitions
# ------------------------------------------------------------

# Proxmox related variables

variable "acn_cpu_cores" {
  description = "The number of CPU cores for the Ansible control node."
  type        = number
}

variable "acn_host_name" {
  description = "Hostname of the Ansible control node."
  type        = string
}

variable "acn_os_template_file" {
  description = "The OS template file for the Ansible control node."
  type        = string
}

variable "acn_os_type" {
  description = "The OS type for the Ansible control node."
  type        = string
}

variable "acn_root_password" {
  description = "Root password for the Ansible control node."
  type        = string
  sensitive   = true
}

variable "acn_storage_size" {
  description = "The storage size for the Ansible control node."
  type        = number
}

variable "acn_memory_size" {
  description = "The memory size for the Ansible control node."
  type        = number
}

variable "acn_vm_id" {
  description = "The VM ID for the Ansible control node."
  type        = number
}

variable "proxmox_api_endpoint" {
  description = "HTTPS endpoint URL of the Proxmox VE API."
  type        = string
}

variable "proxmox_api_token" {
  description = "API token used to authenticate with the Proxmox VE API."
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret (UUID) used by the backup playbook. Injected into the Semaphore environment as PROXMOX_TOKEN_SECRET."
  type        = string
  sensitive   = true
}

variable "proxmox_bridge_name" {
  description = "Name of the Proxmox network bridge to which the container interface is connected."
  type        = string
}

variable "proxmox_datastore" {
  description = "Name of the Proxmox storage datastore used for the container root filesystem."
  type        = string
}

variable "proxmox_interface_name" {
  description = "Name of the network interface inside the container."
  type        = string
}

variable "proxmox_node_name" {
  description = "Name of the Proxmox node where the container will be deployed."
  type        = string
}

variable "proxmox_root_password" {
  description = "Password of the Proxmox root account used for SSH authentication."
  type        = string
  sensitive   = true
}

variable "proxmox_root_user" {
  description = "Username of the Proxmox root account used for SSH authentication."
  type        = string
}

variable "proxmox_ssh_endpoint" {
  description = "Hostname or IP address of the Proxmox host used for SSH connections."
  type        = string
}

variable "proxmox_ssh_key_path" {
  description = "Path to the private SSH key used for authentication to the Proxmox host."
  type        = string
}

variable "proxmox_ssh_port" {
  description = "SSH port used for connections to the Proxmox host."
  type        = number
}