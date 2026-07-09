# -----------------------------------------------------------------------------
# Ansible Playbooks Archive
# -----------------------------------------------------------------------------
# This data source creates a compressed TAR.GZ archive containing all Ansible
# playbooks, roles, inventories, and supporting files located in the local
# 'playbooks' directory.
#
# The generated archive is used by subsequent Terraform resources to transfer
# the complete Ansible project to the target LXC container.
#
# The following actions are performed:
#   - Read the local 'playbooks' directory
#   - Include all files and subdirectories recursively
#   - Create a compressed TAR.GZ archive
#   - Store the archive in the current Terraform module directory
#   - Provide a SHA-256 checksum for change detection
# -----------------------------------------------------------------------------
data "archive_file" "playbooks" {
  type        = "tar.gz"
  source_dir  = "${path.module}/playbooks"
  output_path = "${path.module}/playbooks.tar.gz"
}