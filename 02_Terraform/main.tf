# -----------------------------------------------------------------------------
# LXC Container: backuperia
# -----------------------------------------------------------------------------
# This resource creates an Ubuntu LXC container on the Proxmox VE node.
# The container is automatically started after deployment.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "backuperia" {
  node_name    = var.proxmox_node_name
  vm_id        = var.acn_vm_id
  started      = true
  unprivileged = true

  features {
    nesting = true
  }
  
  initialization {
    hostname = var.acn_host_name

    # The container is configured to use DHCP for its IPv4 address assignment.
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    # The root password is set for the container's root user.
    user_account {
      password = var.acn_root_password
      keys     = [local.acn_ssh_key]
    }
  }

  operating_system {
    template_file_id = var.acn_os_template_file
    type              = var.acn_os_type
  }

  cpu {
    cores = var.acn_cpu_cores
  }

  memory {
    dedicated = var.acn_memory_size
  }

  disk {
    datastore_id = var.proxmox_datastore
    size         = var.acn_storage_size
  }

  network_interface {
    name   = var.proxmox_interface_name
    bridge = var.proxmox_bridge_name
  }
}


# -----------------------------------------------------------------------------
# Dependencies Installation
# -----------------------------------------------------------------------------
# This resource connects to the Proxmox host via SSH and executes commands
# inside the container using the 'pct exec' command.
#
# The following actions are performed:
#   - Update the package index
#   - Install and configure UTF-8 locale support
#   - Enable and start the SSH service
#   - Wait until outbound network connectivity is available
#   - Install required APT utilities
#   - Add the official Ansible PPA repository
#   - Install Ansible and Python pip
#   - Install the Community Proxmox Ansible collection
#   - Install required Python dependencies for Proxmox automation
# -----------------------------------------------------------------------------
resource "null_resource" "install_dependencies" {
  # Ensure this resource is executed only after the LXC container
  # has been successfully created.
  depends_on = [
    proxmox_virtual_environment_container.backuperia
  ]

  # Force recreation of this null_resource whenever the container
  # is replaced. This causes the remote-exec provisioner to run again
  # after a new container has been deployed.
  triggers = {
    container = proxmox_virtual_environment_container.backuperia.id
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_ssh_endpoint
    port        = var.proxmox_ssh_port
    user        = var.proxmox_root_user
    private_key = file(var.proxmox_ssh_key_path)
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      "pct exec 201 -- apt-get update",
      "pct exec 201 -- apt-get install -y locales",
      "pct exec 201 -- locale-gen en_US.UTF-8",
      "pct exec 201 -- update-locale LANG=en_US.UTF-8",
      "pct exec 201 -- systemctl enable --now ssh",
      "for i in $(seq 1 30); do pct exec 201 -- ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && break; sleep 2; done",
      "pct exec 201 -- apt-get install -y software-properties-common",
      "pct exec 201 -- add-apt-repository --yes --update ppa:ansible/ansible",
      "pct exec 201 -- apt-get install -y ansible python3-pip",
      "pct exec 201 -- ansible-galaxy collection install community.proxmox",
      "pct exec 201 -- python3 -m pip install --break-system-packages proxmoxer requests"
    ]
  }
}