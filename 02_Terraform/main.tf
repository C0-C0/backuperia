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
      "pct exec ${var.acn_vm_id} -- apt-get update",
      "pct exec ${var.acn_vm_id} -- apt-get install -y locales",
      "pct exec ${var.acn_vm_id} -- locale-gen en_US.UTF-8",
      "pct exec ${var.acn_vm_id} -- update-locale LANG=en_US.UTF-8",
      "pct exec ${var.acn_vm_id} -- systemctl enable --now ssh",
      "for i in $(seq 1 30); do pct exec ${var.acn_vm_id} -- ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && break; sleep 2; done",
      "pct exec ${var.acn_vm_id} -- apt-get install -y software-properties-common",
      "pct exec ${var.acn_vm_id} -- add-apt-repository --yes --update ppa:ansible/ansible",
      "pct exec ${var.acn_vm_id} -- apt-get install -y ansible python3-pip",
      "pct exec ${var.acn_vm_id} -- ansible-galaxy collection install community.proxmox",
      "pct exec ${var.acn_vm_id} -- python3 -m pip install --break-system-packages proxmoxer requests"
    ]
  }
}


# -----------------------------------------------------------------------------
# Ansible Playbooks Deployment
# -----------------------------------------------------------------------------
# This resource transfers the compressed Ansible playbooks archive to the
# Proxmox VE host and deploys it into the target LXC container.
#
# The resource is executed only after the required dependencies have been
# installed inside the container and the playbooks archive has been created.
#
# A SHA-256 checksum of the archive is used as a trigger to ensure that the
# deployment is automatically repeated whenever the contents of the local
# 'playbooks' directory change.
#
# The following actions are performed:
#   - Wait until the dependencies installation has completed
#   - Wait until the playbooks archive has been generated
#   - Detect changes using the archive SHA-256 checksum
#   - Connect to the Proxmox VE host via SSH
#   - Upload the playbooks archive to the Proxmox host
#   - Copy the archive into the target LXC container
#   - Remove any existing playbooks directory inside the container
#   - Create a fresh destination directory
#   - Extract the archive into the destination directory
#   - Remove the temporary archive from the container
# -----------------------------------------------------------------------------
resource "null_resource" "deploy_playbooks" {

  # Execute this resource only after the dependencies have been installed
  # and the playbooks archive has been successfully created.
  depends_on = [
    null_resource.install_dependencies,
    data.archive_file.playbooks
  ]

  # Re-run this resource whenever the contents of the playbooks directory
  # change, as indicated by the archive SHA-256 checksum.
  triggers = {
    archive_hash = data.archive_file.playbooks.output_sha256
  }

  # SSH connection to the Proxmox VE host.
  connection {
    type        = "ssh"
    host        = var.proxmox_ssh_endpoint
    port        = var.proxmox_ssh_port
    user        = var.proxmox_root_user
    private_key = file(var.proxmox_ssh_key_path)
  }

  # Upload the generated playbooks archive to the Proxmox host.
  provisioner "file" {
    source      = data.archive_file.playbooks.output_path
    destination = "/tmp/playbooks.tar.gz"
  }

  # Copy the archive into the LXC container, replace any existing playbooks,
  # extract the archive, and remove the temporary archive afterwards.
  provisioner "remote-exec" {
    inline = [
      # Copy the archive from the Proxmox host into the LXC container.
      "pct push ${var.acn_vm_id} /tmp/playbooks.tar.gz /root/playbooks.tar.gz",

      # Extract the archive into the destination directory.
      "pct exec ${var.acn_vm_id} -- tar -xzf /root/playbooks.tar.gz -C /etc/ansible",

      # Remove the temporary archive from the container.
      "pct exec ${var.acn_vm_id} -- rm -f /root/playbooks.tar.gz"
    ]
  }
}