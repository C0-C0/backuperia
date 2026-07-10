#!/usr/bin/env bash
# Native (no-Docker) install of Ansible Semaphore + the deps VM_Backup.yml needs.
# Target: Debian/Ubuntu Linux (or WSL). Run from this folder:  sudo ./install.sh
#
# What it does:
#   1. Installs the extra system deps Semaphore itself needs: git, curl, jq, acl.
#      (Ansible, python3-pip and the proxmox python/Galaxy deps are already
#      installed in the container by Terraform — see 02_Terraform/main.tf.)
#   2. Downloads the Semaphore binary to /usr/local/bin.
#   3. Creates the semaphore user, data dir, and a starter config.json
#      (web_host auto-set to this host's IP; sqlite store).
#   4. Grants the semaphore user read access to this repo (local-filesystem repo,
#      run in place — no clone/commit).
#   5. Installs and starts the systemd service.
#   6. (optional, if SEM_ADMIN_PASSWORD set) creates the admin user and
#      provisions the VM-Backup project/template.
set -euo pipefail

SEMAPHORE_VERSION="${SEMAPHORE_VERSION:-2.18.23}"   # override: SEMAPHORE_VERSION=x.y.z ./install.sh
CONFIG_DIR=/etc/semaphore
DATA_DIR=/var/lib/semaphore
BIN=/usr/local/bin/semaphore
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

echo "==> 1/6 System packages"
# Ansible, python3-pip and the proxmox python (proxmoxer/requests) + Galaxy
# (community.proxmox) deps are already installed in the container by Terraform
# (see 02_Terraform/main.tf, null_resource.install_dependencies). Here we only
# add the extra tools Semaphore itself needs.
if command -v apt-get >/dev/null; then
  apt-get update
  apt-get install -y git curl jq acl
else
  echo "!! Non-apt system: install git, curl, jq, acl yourself, then re-run." >&2
fi

echo "==> 2/6 Semaphore binary v${SEMAPHORE_VERSION}"
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

echo "==> 3/6 User, dirs, config"
id -u semaphore >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin semaphore
mkdir -p "$CONFIG_DIR" "$DATA_DIR/tmp"
# --- migrate a legacy bolt config.json to sqlite (bolt is no longer a valid
#     store type in Semaphore 2.18+, which panics "unknown store type") ---
if [[ -f "$CONFIG_DIR/config.json" ]] && grep -q '"bolt"' "$CONFIG_DIR/config.json"; then
  echo "    found legacy bolt config — backing up and regenerating as sqlite"
  mv "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.bolt.bak"
fi
# Detect the container's primary IP so the web UI's links/API base match the
# address you actually browse to (a localhost web_host renders a blank page).
# 'ip route get' returns the source IP of the default route and works even when
# 'hostname -I' comes back empty on a fresh container — that empty result was
# why the URL used to fall back to localhost and need a second run. Fall back to
# 'hostname -I' if 'ip' is unavailable.
# Override with:  WEB_HOST=http://my.host:3000 ./install.sh
# The trailing '|| true' matters: under 'set -euo pipefail' a command-sub whose
# command is missing (e.g. no 'ip' binary -> exit 127) or fails would otherwise
# abort the whole script before the fallback runs.
HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)" || true
[[ -z "$HOST_IP" ]] && HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
WEB_HOST="${WEB_HOST:-http://${HOST_IP:-localhost}:3000}"

if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  # Copy the template, stripping "//" comment keys, filling secrets + web_host.
  WEB_HOST="$WEB_HOST" python3 - "$HERE/config.json.example" "$CONFIG_DIR/config.json" <<'PY'
import json, sys, base64, os
src, dst = sys.argv[1], sys.argv[2]
raw = [l for l in open(src) if not l.lstrip().startswith('"//')]
cfg = json.loads("".join(raw))
for k in ("cookie_hash","cookie_encryption","access_key_encryption"):
    cfg[k] = base64.b64encode(os.urandom(32)).decode()
cfg["web_host"] = os.environ["WEB_HOST"]
json.dump(cfg, open(dst,"w"), indent=2)
PY
  echo "    wrote $CONFIG_DIR/config.json (web_host=$WEB_HOST) with fresh secrets"
else
  # Config already exists: only correct a localhost web_host, leave the rest.
  if grep -q '"web_host": *"http://localhost' "$CONFIG_DIR/config.json"; then
    sed -i "s#\"web_host\": *\"http://localhost:3000\"#\"web_host\": \"$WEB_HOST\"#" "$CONFIG_DIR/config.json"
    echo "    updated existing config web_host -> $WEB_HOST"
  else
    echo "    $CONFIG_DIR/config.json exists — left as-is"
  fi
fi
[[ -f "$CONFIG_DIR/semaphore.env" ]] || cp "$HERE/semaphore.env.example" "$CONFIG_DIR/semaphore.env"
# If a token was passed in (e.g. by Terraform as PROXMOX_TOKEN_SECRET), write it
# into semaphore.env so it replaces the example placeholder. This file is the
# value sourced in step 6 and loaded by the systemd unit, so it must hold the
# real token — otherwise the placeholder would win over the provided env var.
if [[ -n "${PROXMOX_TOKEN_SECRET:-}" ]]; then
  if grep -q '^PROXMOX_TOKEN_SECRET=' "$CONFIG_DIR/semaphore.env"; then
    sed -i "s#^PROXMOX_TOKEN_SECRET=.*#PROXMOX_TOKEN_SECRET=${PROXMOX_TOKEN_SECRET}#" "$CONFIG_DIR/semaphore.env"
  else
    echo "PROXMOX_TOKEN_SECRET=${PROXMOX_TOKEN_SECRET}" >> "$CONFIG_DIR/semaphore.env"
  fi
  echo "    seeded PROXMOX_TOKEN_SECRET into $CONFIG_DIR/semaphore.env"
fi
chown -R semaphore:semaphore "$DATA_DIR" "$CONFIG_DIR"
chmod 600 "$CONFIG_DIR/config.json" "$CONFIG_DIR/semaphore.env"

echo "==> 4/6 Local-filesystem repo access for the semaphore runner"
# Semaphore is configured (in bootstrap.sh) to use this repo as a LOCAL
# FILESYSTEM repository — it runs the files in place (working tree, no clone,
# no commit). The playbook runs as the unprivileged 'semaphore' user, so that
# user must be able to traverse into and read the repo. We grant that with a
# user-scoped ACL (semaphore only) rather than opening the tree world-readable.
ANSIBLE_ROOT="$(cd "$HERE/.." && pwd)"   # parent of dashboard/ = deploy dir (/etc/ansible in the container)
REPO_PATH="${REPO_PATH:-$ANSIBLE_ROOT}"  # override if the files live elsewhere
grant_semaphore_read() {
  local repo="$1"
  if command -v setfacl >/dev/null; then
    # read+traverse on the whole tree, and as the default for future files.
    setfacl -R  -m u:semaphore:rX "$repo"
    setfacl -R -d -m u:semaphore:rX "$repo"
    # traverse-only (x) on each parent dir so 'semaphore' can reach the repo
    # even if it lives under a 0700 home like /root. This exposes traversal,
    # not listing, of those parents to the semaphore user.
    local d; d="$(dirname "$repo")"
    while [[ "$d" != "/" && -n "$d" ]]; do
      setfacl -m u:semaphore:x "$d" 2>/dev/null || true
      d="$(dirname "$d")"
    done
    echo "    granted semaphore rX (ACL) on $repo, +traverse on its parents"
  else
    chmod -R o+rX "$repo"
    echo "    'acl' not available — used chmod o+rX (world-readable) on $repo"
  fi
}
grant_semaphore_read "$REPO_PATH"
if sudo -u semaphore test -r "$REPO_PATH/inventory.yml"; then
  echo "    OK: semaphore can read $REPO_PATH"
else
  echo "    !! semaphore still cannot read $REPO_PATH — check parent dir perms" >&2
fi

echo "==> 5/6 systemd service"
install -m 0644 "$HERE/semaphore.service" /etc/systemd/system/semaphore.service
systemctl daemon-reload
systemctl enable semaphore
# Use restart (not 'enable --now') so a web_host/config change made above always
# takes effect in this same run — 'enable --now' is a no-op on an already-running
# unit, which is why a corrected URL previously needed a second run.
systemctl restart semaphore

# Wait until the API answers before creating the admin / provisioning. On a fresh
# install the DB is created and migrated on first start; 'user add' against a
# not-yet-ready DB fails and would be misreported below as "already exists".
SEM_URL="${SEM_URL:-http://localhost:3000}"
echo "    waiting for Semaphore API at $SEM_URL"
for i in $(seq 1 30); do
  curl -fsS "$SEM_URL/api/ping" >/dev/null 2>&1 && break
  sleep 1
  [[ $i -eq 30 ]] && echo "    !! API not responding yet — continuing anyway" >&2
done
echo
echo "Semaphore is running. Open the dashboard at:  ${WEB_HOST}"
echo "(web_host in $CONFIG_DIR/config.json — re-run with WEB_HOST=... to change it.)"

# ==> 6/6 (optional) Admin user + auto-provision the VM-Backup template.
# Set SEM_ADMIN_PASSWORD to have install.sh finish the whole setup so the
# playbook is already registered and ready to Run. Semaphore uses the repo's
# files IN PLACE (local filesystem repo) — nothing is pulled from GitHub.
#   sudo SEM_ADMIN_PASSWORD='S3cret!' ./install.sh
if [[ -n "${SEM_ADMIN_PASSWORD:-}" ]]; then
  SEM_ADMIN_LOGIN="${SEM_ADMIN_LOGIN:-admin}"
  echo "==> 6/6 Admin user + provisioning"
  # Create the admin. Idempotent, but distinguish a real failure from a genuine
  # "already exists" so a broken run isn't silently reported as success.
  if admin_out="$(sudo -u semaphore "$BIN" user add --admin --config "$CONFIG_DIR/config.json" \
      --login "$SEM_ADMIN_LOGIN" --name Admin --email "${SEM_ADMIN_EMAIL:-admin@example.com}" \
      --password "$SEM_ADMIN_PASSWORD" 2>&1)"; then
    echo "    created admin '$SEM_ADMIN_LOGIN'"
  elif echo "$admin_out" | grep -qi 'exist'; then
    echo "    admin '$SEM_ADMIN_LOGIN' already exists — continuing"
  else
    echo "    !! could not create admin '$SEM_ADMIN_LOGIN': $admin_out" >&2
  fi
  # Seed project/repo/inventory/environment/template via the API.
  # Pull the Proxmox token from semaphore.env if present so it lands in the UI env.
  [[ -f "$CONFIG_DIR/semaphore.env" ]] && . "$CONFIG_DIR/semaphore.env" 2>/dev/null || true
  SEM_URL="$SEM_URL" SEM_WEB_URL="$WEB_HOST" \
  SEM_ADMIN_LOGIN="$SEM_ADMIN_LOGIN" SEM_ADMIN_PASSWORD="$SEM_ADMIN_PASSWORD" \
  GIT_URL="${GIT_URL:-$REPO_PATH}" GIT_BRANCH="${GIT_BRANCH:-main}" \
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
