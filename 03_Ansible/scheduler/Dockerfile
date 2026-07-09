# Semaphore runner image with the extras the backup playbook needs.
# Semaphore auto-clones the repo and runs ansible, but it does NOT install
# Python libraries, and community.proxmox needs proxmoxer>=2.3.
FROM semaphoreui/semaphore:latest

USER root

# 1) Python dependency for the proxmox modules.
RUN pip3 install --no-cache-dir --break-system-packages 'proxmoxer>=2.3' requests \
 || pip3 install --no-cache-dir 'proxmoxer>=2.3' requests

# 2) Bake the collection into a global path so the runner always finds it,
#    independent of Semaphore's requirements auto-detection.
RUN ansible-galaxy collection install community.proxmox \
      --collections-path /usr/share/ansible/collections
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections

# NOTE: community.proxmox 2.x needs ansible-core >= 2.17. If the bundled
# ansible is older (check: docker exec semaphore ansible --version), either
# add:  RUN pip3 install --break-system-packages 'ansible-core>=2.17'
# or switch the playbook back to community.general 10.x (see README).

USER semaphore
