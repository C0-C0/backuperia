#!/usr/bin/env bash
# Seed a fresh Semaphore instance so the VM-Backup playbook is already
# registered (project + repo + inventory + environment + task template) and
# ready to Run — no manual clicking in the web UI.
#
# Idempotent: re-running skips objects that already exist (matched by name).
#
# Usage (after install.sh has Semaphore running on :3000):
#   SEM_URL=http://localhost:3000 \
#   SEM_ADMIN_LOGIN=admin SEM_ADMIN_PASSWORD='CHANGE_ME' \
#   ./bootstrap.sh
#
# By default Semaphore uses the LOCAL FILES already on the host, IN PLACE — the
# repository is registered as a bare filesystem path (not file://), so Semaphore
# runs the working tree directly: no clone, no commit needed, edits to
# inventory.yml/VM_Backup.yml take effect on the next Run. Nothing is fetched
# from GitHub. Override GIT_URL only if you want it to pull from a remote instead.
#
# Optional:
#   PROJECT_NAME       (default: Backuperia)
#   TEMPLATE_NAME      (default: VM-Backup)
#   PLAYBOOK           (default: VM_Backup.yml, relative to the deploy dir)
#   INVENTORY_PATH     (default: inventory.yml, relative to the deploy dir)
#   GIT_URL            (default: the deploy dir, e.g. /etc/ansible) -- remote optional
#   GIT_SSH_KEY_FILE   private key, only for a remote private repo
#   PROXMOX_TOKEN_SECRET  injected into the Semaphore Environment (encrypted)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Directory the Ansible files were deployed to — the parent of this dashboard
# folder (VM_Backup.yml and inventory.yml sit directly in it). In the container
# Terraform extracts them to /etc/ansible, so this is /etc/ansible; Semaphore
# runs the files there in place (local filesystem repo, no clone from GitHub).
ANSIBLE_ROOT="$(cd "$HERE/.." && pwd)"

SEM_URL="${SEM_URL:-http://localhost:3000}"
# API calls go to SEM_URL (localhost, always reachable on the host). The URL we
# tell the user to open is SEM_WEB_URL — the container's real address — since
# 'localhost' only works from inside the container.
SEM_WEB_URL="${SEM_WEB_URL:-$SEM_URL}"
SEM_ADMIN_LOGIN="${SEM_ADMIN_LOGIN:-admin}"
SEM_ADMIN_PASSWORD="${SEM_ADMIN_PASSWORD:?set SEM_ADMIN_PASSWORD}"
# Bare path (no file://) => Semaphore "local filesystem" repo: used in place,
# working tree, no clone. A file:// URL would instead clone (committed only).
GIT_URL="${GIT_URL:-$ANSIBLE_ROOT}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_NAME="${PROJECT_NAME:-Backuperia}"
TEMPLATE_NAME="${TEMPLATE_NAME:-VM-Backup}"
PLAYBOOK="${PLAYBOOK:-VM_Backup.yml}"
INVENTORY_PATH="${INVENTORY_PATH:-inventory.yml}"
GIT_SSH_KEY_FILE="${GIT_SSH_KEY_FILE:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

command -v jq >/dev/null || { echo "!! this script needs 'jq' (apt-get install -y jq)"; exit 1; }

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT

api() { # api METHOD PATH [json-body]  -> prints body, exits with the server's error text on failure
  local method="$1" path="$2" body="${3:-}" out code
  if [[ -n "$body" ]]; then
    out="$(curl -sS -w $'\n%{http_code}' -b "$COOKIE" -c "$COOKIE" \
      -H 'Content-Type: application/json' -X "$method" "$SEM_URL$path" -d "$body")"
  else
    out="$(curl -sS -w $'\n%{http_code}' -b "$COOKIE" -c "$COOKIE" -X "$method" "$SEM_URL$path")"
  fi
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" -ge 400 ]]; then
    echo "!! $method $path -> HTTP $code: $out" >&2
    return 1
  fi
  printf '%s' "$out"
}

echo "==> waiting for Semaphore at $SEM_URL"
for i in $(seq 1 30); do
  curl -fsS "$SEM_URL/api/ping" >/dev/null 2>&1 && break
  sleep 1
  [[ $i -eq 30 ]] && { echo "!! Semaphore not responding at $SEM_URL"; exit 1; }
done

echo "==> logging in as $SEM_ADMIN_LOGIN"
curl -fsS -c "$COOKIE" -H 'Content-Type: application/json' \
  -X POST "$SEM_URL/api/auth/login" \
  -d "$(jq -n --arg a "$SEM_ADMIN_LOGIN" --arg p "$SEM_ADMIN_PASSWORD" \
        '{auth:$a, password:$p}')" >/dev/null

# --- Project ---------------------------------------------------------------
PROJECT_ID="$(api GET /api/projects | jq -r --arg n "$PROJECT_NAME" \
  '.[] | select(.name==$n) | .id' | head -n1)"
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(api POST /api/projects \
    "$(jq -n --arg n "$PROJECT_NAME" '{name:$n, alert:false}')" | jq -r '.id')"
  echo "    created project '$PROJECT_NAME' (id $PROJECT_ID)"
else
  echo "    project '$PROJECT_NAME' exists (id $PROJECT_ID)"
fi
P="/api/project/$PROJECT_ID"

# --- Git key (SSH private key, or a 'None' key for public repos) -----------
KEY_ID="$(api GET "$P/keys" | jq -r '.[] | select(.name=="git") | .id' | head -n1)"
if [[ -z "$KEY_ID" ]]; then
  if [[ -n "$GIT_SSH_KEY_FILE" ]]; then
    KEY_ID="$(api POST "$P/keys" "$(jq -n --argjson pid "$PROJECT_ID" \
      --arg pk "$(cat "$GIT_SSH_KEY_FILE")" \
      '{name:"git", type:"ssh", project_id:$pid, ssh:{login:"git", passphrase:"", private_key:$pk}}')" \
      | jq -r '.id')"
    echo "    added SSH git key (id $KEY_ID)"
  else
    KEY_ID="$(api POST "$P/keys" "$(jq -n --argjson pid "$PROJECT_ID" \
      '{name:"git", type:"none", project_id:$pid}')" | jq -r '.id')"
    echo "    added 'None' git key for public repo (id $KEY_ID)"
  fi
else
  echo "    git key exists (id $KEY_ID)"
fi

# --- Repository ------------------------------------------------------------
REPO_ID="$(api GET "$P/repositories" | jq -r '.[] | select(.name=="backuperia") | .id' | head -n1)"
if [[ -z "$REPO_ID" ]]; then
  REPO_ID="$(api POST "$P/repositories" "$(jq -n \
    --arg u "$GIT_URL" --arg b "$GIT_BRANCH" --argjson k "$KEY_ID" --argjson pid "$PROJECT_ID" \
    '{name:"backuperia", project_id:$pid, git_url:$u, git_branch:$b, ssh_key_id:$k}')" | jq -r '.id')"
  echo "    added repository (id $REPO_ID)"
else
  echo "    repository exists (id $REPO_ID)"
fi

# --- Inventory (File type, path into the repo checkout) --------------------
INV_ID="$(api GET "$P/inventory" | jq -r '.[] | select(.name=="backuperia") | .id' | head -n1)"
if [[ -z "$INV_ID" ]]; then
  INV_ID="$(api POST "$P/inventory" "$(jq -n \
    --arg path "$INVENTORY_PATH" --argjson k "$KEY_ID" --argjson pid "$PROJECT_ID" \
    '{name:"backuperia", project_id:$pid, type:"file", inventory:$path, ssh_key_id:$k, become_key_id:$k}')" \
    | jq -r '.id')"
  echo "    added inventory (id $INV_ID)"
else
  echo "    inventory exists (id $INV_ID)"
fi

# --- Environment (holds PROXMOX_TOKEN_SECRET, stored encrypted) ------------
ENV_ID="$(api GET "$P/environment" | jq -r '.[] | select(.name=="backuperia") | .id' | head -n1)"
if [[ -z "$ENV_ID" ]]; then
  ENV_JSON="{}"
  [[ -n "$PROXMOX_TOKEN_SECRET" ]] && \
    ENV_JSON="$(jq -n --arg s "$PROXMOX_TOKEN_SECRET" '{PROXMOX_TOKEN_SECRET:$s}')"
  ENV_ID="$(api POST "$P/environment" "$(jq -n \
    --arg e "$ENV_JSON" --argjson pid "$PROJECT_ID" \
    '{name:"backuperia", project_id:$pid, json:"{}", env:$e}')" | jq -r '.id')"
  echo "    added environment (id $ENV_ID)"
else
  echo "    environment exists (id $ENV_ID)"
fi

# --- Task template: the VM-Backup playbook ---------------------------------
TPL_ID="$(api GET "$P/templates" | jq -r --arg n "$TEMPLATE_NAME" \
  '.[] | select(.name==$n) | .id' | head -n1)"
if [[ -z "$TPL_ID" ]]; then
  api POST "$P/templates" "$(jq -n \
    --arg n "$TEMPLATE_NAME" --arg pb "$PLAYBOOK" --argjson pid "$PROJECT_ID" \
    --argjson inv "$INV_ID" --argjson repo "$REPO_ID" --argjson env "$ENV_ID" \
    '{name:$n, project_id:$pid, app:"ansible", playbook:$pb, inventory_id:$inv,
      repository_id:$repo, environment_id:$env, type:"", arguments:"[]"}')" >/dev/null
  echo "    registered task template '$TEMPLATE_NAME'"
else
  echo "    task template '$TEMPLATE_NAME' exists (id $TPL_ID)"
fi

echo
echo "Done. Open $SEM_WEB_URL → project '$PROJECT_NAME' → template '$TEMPLATE_NAME' is ready to Run."
[[ -z "$PROXMOX_TOKEN_SECRET" ]] && \
  echo "Note: set PROXMOX_TOKEN_SECRET (env or /etc/semaphore/semaphore.env) before the first real run."
