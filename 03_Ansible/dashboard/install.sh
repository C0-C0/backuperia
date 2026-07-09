#!/usr/bin/env bash
# Native (no-Docker) install of Ansible Semaphore + the deps VM_Backup.yml needs.
# Target: Debian/Ubuntu Linux (or WSL). Run from this folder:  sudo ./install.sh
#
# What it does:
#   1. Installs system deps: ansible-core, python3 + pip, git, curl.
#   2. Installs the Python + Galaxy deps the proxmox modules need.
#   3. Downloads the Semaphore binary to /usr/local/bin.
#   4. Creates the semaphore user, data dir, and a starter config.json.
#   5. Installs the systemd service and (optionally) creates the admin user.
set -euo pipefail

SEMAPHORE_VERSION="${SEMAPHORE_VERSION:-2.18.23}"   # override: SEMAPHORE_VERSION=x.y.z ./install.sh
CONFIG_DIR=/etc/semaphore
DATA_DIR=/var/lib/semaphore
BIN=/usr/local/bin/semaphore
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

echo "==> 1/5 System packages"
if command -v apt-get >/dev/null; then
  apt-get update
  apt-get install -y ansible-core python3 python3-pip git curl jq
else
  echo "!! Non-apt system: install ansible-core, python3-pip, git, curl yourself, then re-run." >&2
fi

echo "==> 2/5 Python + Ansible Galaxy deps for the proxmox modules"
pip3 install --break-system-packages 'proxmoxer>=2.3' requests 2>/dev/null \
  || pip3 install 'proxmoxer>=2.3' requests
# Install the collection globally so the semaphore user always finds it.
ansible-galaxy collection install -r "${HERE}/requirements.yml" \
  --collections-path /usr/share/ansible/collections

echo "==> 3/5 Semaphore binary v${SEMAPHORE_VERSION}"
arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
  amd64|x86_64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
esac
# NOTE: use the *community* (open-source) build. The plain "semaphore_..."
# asset is the Pro binary, whose store factory panics ("unknown store type")
# on a community BoltDB config.
url="https://github.com/semaphoreui/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_community_${SEMAPHORE_VERSION}_linux_${arch}.tar.gz"
tmp="$(mktemp -d)"
curl -fsSL "$url" -o "$tmp/semaphore.tar.gz"
tar -xzf "$tmp/semaphore.tar.gz" -C "$tmp" semaphore
install -m 0755 "$tmp/semaphore" "$BIN"
rm -rf "$tmp"
echo "    installed: $($BIN version 2>/dev/null || echo "$BIN")"

echo "==> 4/5 User, dirs, config"
id -u semaphore >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin semaphore
mkdir -p "$CONFIG_DIR" "$DATA_DIR/tmp"
# --- migrate a legacy bolt config.json to sqlite (bolt is no longer a valid
#     store type in Semaphore 2.18+, which panics "unknown store type") ---
if [[ -f "$CONFIG_DIR/config.json" ]] && grep -q '"bolt"' "$CONFIG_DIR/config.json"; then
  echo "    found legacy bolt config — backing up and regenerating as sqlite"
  mv "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.bolt.bak"
fi
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  # Copy the template, stripping "//" comment keys and filling real secrets.
  python3 - "$HERE/config.json.example" "$CONFIG_DIR/config.json" <<'PY'
import json, sys, base64, os
src, dst = sys.argv[1], sys.argv[2]
raw = [l for l in open(src) if not l.lstrip().startswith('"//')]
cfg = json.loads("".join(raw))
for k in ("cookie_hash","cookie_encryption","access_key_encryption"):
    cfg[k] = base64.b64encode(os.urandom(32)).decode()
json.dump(cfg, open(dst,"w"), indent=2)
PY
  echo "    wrote $CONFIG_DIR/config.json with fresh random secrets"
else
  echo "    $CONFIG_DIR/config.json exists — left as-is"
fi
[[ -f "$CONFIG_DIR/semaphore.env" ]] || cp "$HERE/semaphore.env.example" "$CONFIG_DIR/semaphore.env"
chown -R semaphore:semaphore "$DATA_DIR" "$CONFIG_DIR"
chmod 600 "$CONFIG_DIR/config.json" "$CONFIG_DIR/semaphore.env"

echo "==> 5/5 systemd service"
install -m 0644 "$HERE/semaphore.service" /etc/systemd/system/semaphore.service
systemctl daemon-reload
systemctl enable --now semaphore
echo
echo "Semaphore is running on port 3000 (see web_host in $CONFIG_DIR/config.json)."

# ==> 6/6 (optional) Admin user + auto-provision the VM-Backup template.
# Set SEM_ADMIN_PASSWORD to have install.sh finish the whole setup so the
# playbook is already registered and ready to Run. Semaphore uses the LOCAL
# copy of this repo on the host (file://) — nothing is pulled from GitHub.
#   sudo SEM_ADMIN_PASSWORD='S3cret!' ./install.sh
if [[ -n "${SEM_ADMIN_PASSWORD:-}" ]]; then
  SEM_ADMIN_LOGIN="${SEM_ADMIN_LOGIN:-admin}"
  echo "==> 6/6 Admin user + provisioning"
  # Create the admin (idempotent: ignore "already exists").
  sudo -u semaphore "$BIN" user add --admin --config "$CONFIG_DIR/config.json" \
    --login "$SEM_ADMIN_LOGIN" --name Admin --email "${SEM_ADMIN_EMAIL:-admin@example.com}" \
    --password "$SEM_ADMIN_PASSWORD" 2>/dev/null \
    && echo "    created admin '$SEM_ADMIN_LOGIN'" \
    || echo "    admin '$SEM_ADMIN_LOGIN' already exists — continuing"
  # Seed project/repo/inventory/environment/template via the API.
  # Pull the Proxmox token from semaphore.env if present so it lands in the UI env.
  [[ -f "$CONFIG_DIR/semaphore.env" ]] && . "$CONFIG_DIR/semaphore.env" 2>/dev/null || true
  SEM_URL="${SEM_URL:-http://localhost:3000}" \
  SEM_ADMIN_LOGIN="$SEM_ADMIN_LOGIN" SEM_ADMIN_PASSWORD="$SEM_ADMIN_PASSWORD" \
  GIT_URL="${GIT_URL:-}" GIT_BRANCH="${GIT_BRANCH:-main}" \
  GIT_SSH_KEY_FILE="${GIT_SSH_KEY_FILE:-}" \
  PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}" \
    bash "$HERE/bootstrap.sh"
else
  echo "Create the admin user (interactive):"
  echo "  sudo -u semaphore $BIN user add --admin --config $CONFIG_DIR/config.json \\"
  echo "       --login admin --name Admin --email admin@example.com --password 'CHANGE_ME'"
  echo
  echo "Then pre-register the VM-Backup template from the LOCAL repo (no GitHub):"
  echo "  SEM_ADMIN_PASSWORD='...' $HERE/bootstrap.sh"
  echo
  echo "Or do it all in one shot on a fresh host:"
  echo "  sudo SEM_ADMIN_PASSWORD='...' ./install.sh"
fi
echo
echo "Set the Proxmox token in $CONFIG_DIR/semaphore.env and: sudo systemctl restart semaphore"
