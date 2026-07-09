# Scheduler + dashboard: Ansible Semaphore (native, no Docker)

[Semaphore](https://github.com/semaphoreui/semaphore) is a web UI that clones
this repo, runs `VM_Backup.yml` on a cron schedule, and gives you a run-history
dashboard (per-run status, live logs, duration) — the scheduler and the
dashboard in one service.

This folder runs Semaphore **natively** — a single Go binary managed by systemd,
with an embedded SQLite file (no Docker, no Postgres).

```
semaphore (systemd service, native binary)
  ├─ Schedule (cron) ─▶ Task Template ─▶ ansible-playbook 03_Ansible/VM_Backup.yml
  ├─ Repository        (this repo, used in place — local filesystem, no clone)
  ├─ Inventory         (03_Ansible/inventory.yml)
  ├─ Environment       (secret: PROXMOX_TOKEN_SECRET)
  └─ Store             (SQLite file at /var/lib/semaphore/database.sqlite)
  Dashboard: task history, pass/fail, logs, run duration
```

## Requirements (install before running)

Semaphore runs Ansible directly, so it must live on a **Linux host** (or WSL on
Windows) — Ansible has no native Windows controller. The `install.sh` script
installs everything below; this list is what it puts in place:

| Requirement | Why | Version |
| --- | --- | --- |
| Linux host, always-on | Semaphore + Ansible controller | Debian/Ubuntu (apt) assumed by `install.sh` |
| `ansible-core` | runs the playbook | **>= 2.17** (community.proxmox 2.x needs it) |
| `python3` + `python3-pip` | Ansible + proxmox modules | 3.9+ |
| `proxmoxer` (pip) | Proxmox API client the modules use | **>= 2.3** |
| `requests` (pip) | HTTP for proxmoxer | any recent |
| `community.proxmox` (Galaxy collection) | provides `proxmox_backup` | 2.x (see [requirements.yml](requirements.yml)) |
| `git` | Semaphore clones this repo | any |
| `curl` | download the Semaphore binary | any |
| Semaphore binary | scheduler + dashboard | 2.18.x (pinned in `install.sh`, override with `SEMAPHORE_VERSION`) |

> **ansible-core version:** if `ansible --version` shows older than 2.17,
> `pip3 install --break-system-packages 'ansible-core>=2.17'`, or switch the
> playbook module to `community.general.proxmox_backup` (10.x line).

## 1. Install and start Semaphore

On the Linux host, from this folder:

```bash
cd 03_Ansible/dashboard
sudo ./install.sh
```

The script installs the deps, drops the binary at `/usr/local/bin/semaphore`,
writes `/etc/semaphore/config.json` (with fresh random secrets), installs the
`semaphore.service` systemd unit, and starts it on port **3000**.

Create the admin user (interactive prompt for the password, or pass `--password`):

```bash
sudo -u semaphore /usr/local/bin/semaphore user add --admin \
     --config /etc/semaphore/config.json \
     --login admin --name Admin --email admin@example.com --password 'CHANGE_ME'
```

Sanity-check the runner has what it needs:

```bash
ansible --version                                   # want ansible-core >= 2.17
python3 -c 'import proxmoxer; print(proxmoxer.__version__)'   # want >= 2.3
```

Open `http://<host>:3000` and log in.

### Manual install (if you don't use the script)

1. Install the requirements from the table above.
2. Download the binary from the [releases page](https://github.com/semaphoreui/semaphore/releases),
   `install -m0755 semaphore /usr/local/bin/`.
3. `cp config.json.example /etc/semaphore/config.json`, fill the three
   `access_key_encryption` / `cookie_*` secrets (`head -c32 /dev/urandom | base64`).
4. `cp semaphore.service /etc/systemd/system/`, `systemctl enable --now semaphore`.

## 2. Configure the project

### Automatic (recommended) — everything pre-registered

`bootstrap.sh` seeds Semaphore via its REST API so the **`VM-Backup`** template is
already there (project, git key, repository, inventory, environment, task
template) the first time you log in — no clicking through the UI.

It registers this repo as a **local-filesystem repository** — a bare host path
(e.g. `/opt/backuperia`), *not* a `file://` URL. Semaphore runs the files **in
place, from the working tree**: no clone, no commit needed. Edit
`inventory.yml`/`VM_Backup.yml` on the host and the change takes effect on the
next Run. Nothing is fetched from GitHub.

Because the playbook runs as the unprivileged **`semaphore`** user, that user
needs read access to the repo. `install.sh` grants it automatically (step 5)
with a `semaphore`-scoped ACL, and traverse on the parent dirs — so the repo can
even live under `/root`. Override the path with `REPO_PATH=/opt/backuperia`.

Do it in one shot on a fresh host by passing just the admin password to
`install.sh`:

```bash
cd 03_Ansible/dashboard
sudo SEM_ADMIN_PASSWORD='S3cret!' ./install.sh
```

`install.sh` then creates the admin user and runs `bootstrap.sh`. To seed the
Proxmox secret too, put it in `/etc/semaphore/semaphore.env` first (it's read
automatically) or pass `PROXMOX_TOKEN_SECRET=...`.

Run it standalone against an already-installed Semaphore:

```bash
SEM_ADMIN_LOGIN=admin SEM_ADMIN_PASSWORD='S3cret!' ./bootstrap.sh
```

> Want it to pull from a remote instead of the local files? Set
> `GIT_URL=git@github.com:C0-C0/backuperia.git` (and `GIT_SSH_KEY_FILE=...` for a
> private repo).

It's idempotent — objects that already exist (matched by name) are left alone,
so re-running is safe. Then jump to [section 3](#3-test-then-schedule) to Run and
schedule.

### Manual (web UI)

1. **Create Project** → name it `Backuperia`.
2. **Key Store** → add a **None**-type key (named `git`); a local-filesystem
   repo needs no credentials.
3. **Repository** → **URL = the host path to this repo** (bare path, e.g.
   `/opt/backuperia` — *not* `file://`, which would clone), branch `main`, the
   `git` key above. Semaphore runs the files in place from the working tree.
4. **Inventory** → type **File**, path `03_Ansible/inventory.yml`.
5. **Environment** → create one (named `backuperia`); it can be empty. The
   Proxmox token secret is entered **directly in `03_Ansible/inventory.yml`**
   (`proxmox_api_token_secret:`) in this setup, so no env var is needed. (If you
   prefer to keep the secret out of the file, put
   `{ "PROXMOX_TOKEN_SECRET": "..." }` here instead and change the inventory
   field to `"{{ lookup('env','PROXMOX_TOKEN_SECRET') }}"`.)
6. **Task Template** →
   - Playbook: `03_Ansible/VM_Backup.yml`
   - Inventory / Repository / Environment: the ones above.
   - (Optional) enable requirements install pointing at
     `03_Ansible/dashboard/requirements.yml` — though `install.sh` already put
     the collection on the host globally.

## 3. Test, then schedule

- Open the template → **Run** once. Watch the live log; the task should go green
  and the backup should land on `usbBCK` (verify in the PVE UI).
- Add a **Schedule** on the template with cron `0 2 * * *` (daily 02:00).

The **Dashboard** (project → Tasks) now shows every run: who/what triggered it,
pass/fail, duration, and full logs — your "run success/history" view.

## Operating the service

```bash
sudo systemctl status semaphore      # health
sudo journalctl -u semaphore -f      # live server logs
sudo systemctl restart semaphore     # after editing config.json or semaphore.env
```

## Notes / gotchas

- **Secrets:** `/etc/semaphore/config.json` and `/etc/semaphore/semaphore.env`
  hold secrets and are chmod 600, owned by the `semaphore` user. This folder's
  `.gitignore` keeps local copies out of git; only the `.example` files are
  committed.
- **Alerts:** Semaphore can email/webhook on failure — set `email_alert` in
  config.json and configure alerts under the project settings once runs work.
- **First real run:** narrow `vmids` to one guest to validate end-to-end before
  backing up all three.
- **Upgrades:** `SEMAPHORE_VERSION=x.y.z sudo ./install.sh` re-downloads the
  binary and restarts the service; the SQLite data is untouched.
