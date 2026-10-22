# Company Infrastructure — EspoCRM on Docker

Fully automated Ansible-driven deployment of EspoCRM with Traefik reverse proxy,
MariaDB, Redis, Uptime Kuma monitoring, and nightly backups. Deployed on a
Hostinger VPS behind Cloudflare, with GitHub Actions CI/CD.

---

## Architecture

```
                         Cloudflare (proxy + DNS)
                               │
                         ┌─────┴─────┐
                    HTTPS :443    HTTP :80
                         │           │
                         ▼           │
              ┌──────────────────────┘
              │       Traefik v3.3
              │  (reverse proxy + SSL)
              │  File provider (static routes)
              │  DNS challenge via Cloudflare
              │  Let's Encrypt certificates
              └────┬──────┬──────────┐
                   │      │          │
         ┌─────────┘      │          └──────────┐
         ▼                ▼                     ▼
   EspoCRM :80      Uptime Kuma :3001     Dashboard :8080
   (Apache/PHP)     (monitoring)          (Traefik API)
         │
    ┌────┴────┐
    ▼         ▼
 MariaDB    Redis
 :3306     :6379
```

**Networks:** `traefik_web` (external, 172.20.0.0/24) + `backend` (internal, 172.21.0.0/24)

**Hostnames:**

| Service | URL | Auth |
|---|---|---|
| EspoCRM | https://crm.educollege.in | admin / vault |
| Dashboard | https://traefik.educollege.in | admin / auto-generated |
| Status | https://status.educollege.in | First-visit setup |

---

## Project Structure

```
.
├── .ansible-lint                  # linter suppression rules
├── .github/workflows/deploy.yml   # CI/CD pipeline
├── .gitignore
├── Makefile                       # shortcut commands
├── README.md
├── ansible.cfg                    # Ansible global config
├── requirements.yml               # Ansible Galaxy collections
│
├── inventory/
│   ├── production.ini             # VPS target (200.97.165.13)
│   └── group_vars/
│       └── all.yml                # domain, email, Docker user
│
├── vault/
│   └── secrets.yml                # ENCRYPTED — passwords, tokens
│
├── playbooks/
│   ├── site.yml                   # master: runs everything
│   ├── bootstrap.yml              # common + firewall + fail2ban
│   ├── docker.yml                 # Docker engine + networks
│   ├── traefik.yml                # Docker + Traefik
│   ├── espocrm.yml                # EspoCRM + MariaDB + Redis
│   ├── monitoring.yml             # Uptime Kuma
│   ├── backup.yml                 # cron jobs for backups
│   └── cleanup.yml                # docker system prune
│
└── roles/
    ├── common/         # apt update, packages, timezone
    ├── firewall/       # UFW (allow 22, 80, 443)
    ├── fail2ban/       # brute-force protection
    ├── docker/         # install, daemon, networks, test app, cleanup
    ├── traefik/        # reverse proxy + SSL (file-based routing)
    ├── espocrm/        # CRM application stack
    ├── monitoring/     # Uptime Kuma
    ├── backup/         # DB + volume backup scripts
    └── ssh/            # future SSH hardening (stub)
```

---

## Prerequisites

- Python 3.10+ with `ansible` installed
- Ansible Galaxy collections installed: `ansible-galaxy collection install -r requirements.yml`
- SSH key `~/.ssh/id_ed25519_hostinger_crm` added to VPS `deploy` user
- Cloudflare API token with Zone:DNS:Edit permission on the domain
- GitHub repo with the following secrets/variables (see below)

---

## Quick Deploy

```bash
# 1. Clone and cd
git clone https://github.com/lifesparxconsultech/espocrm-ansible-infra.git
cd espocrm-ansible-infra

# 2. Install collections
ansible-galaxy collection install -r requirements.yml

# 3. Configure vault (edit passwords BEFORE encrypting)
ansible-vault edit vault/secrets.yml
# Set: espocrm_db_password, espocrm_admin_password, cloudflare_api_token

# 4. Verify connectivity
make ping

# 5. Deploy everything
make deploy
```

### Makefile targets

| Command | Action |
|---|---|
| `make ping` | Test SSH connectivity |
| `make bootstrap` | Run Phase 1-2 (OS, firewall, fail2ban) |
| `make docker` | Run Phase 3 (Docker engine + networks) |
| `make traefik` | Run Phase 4 (Traefik + SSL) |
| `make espocrm` | Run Phase 8 (CRM stack) |
| `make monitoring` | Run Phase 6 (Uptime Kuma) |
| `make backup` | Run Phase 7 (backup cron jobs) |
| `make deploy` | Run site.yml (all phases) |
| `make cleanup` | Docker system prune |
| `make lint` | Run ansible-lint |
| `make syntax` | Syntax-check all playbooks |

---

## Phase Breakdown

### Phase 1 — Foundation
- Updates apt cache, installs common packages (curl, git, htop, tmux, etc.)
- Enables unattended-upgrades
- Sets timezone to UTC

### Phase 2 — Bootstrap Roles
- Configures UFW: allows SSH (22), HTTP (80), HTTPS (443)
- Installs and enables Fail2ban for brute-force protection

### Phase 3 — Docker Platform
- Installs Docker Engine + Docker Compose plugin from official repo
- Adds `deploy` user to `docker` group
- Configures daemon.json: JSON-file logging (10MB × 3), overlay2, live-restore, metrics on :9323
- Creates Docker networks: `traefik_web` (172.20.0.0/24) and `backend` (172.21.0.0/24, internal)
- Deploys Nginx test app on port 8080 (verification container)
- Cron: daily `docker system prune -af` and volume cleanup
- Logrotate for Docker container logs

### Phase 4 — Traefik Reverse Proxy
- Traefik v3.3 with file-based static routing (NOT Docker provider — bypasses Docker 29.x API incompatibility)
- Let's Encrypt via Cloudflare DNS challenge (works behind Cloudflare proxy)
- Dynamic config defines all routers, middlewares, and services
- Security headers middleware (HSTS, XSS, frame options, CSP)
- Rate limiting middleware (100 req/s, burst 50)
- Compression middleware
- Dashboard with basic auth
- Health check via ping entrypoint on :8082
- **Why file provider:** Docker 29.6.1 requires API version 1.40 minimum, but Traefik's embedded Go Docker client negotiates at 1.24. File-based routing avoids this entirely.

### Phase 5 — GitHub Actions CI/CD
- Triggers on push/PR to `main` for playbooks, roles, inventory, or workflow changes
- Manual trigger via `workflow_dispatch` with playbook selector
- Three jobs: lint (ansible-lint + yamllint) → syntax check → deploy
- SSH key added to ssh-agent with passphrase support
- Vault password written to temp file for decryption
- Discord notifications on success/failure (optional — needs `DISCORD_WEBHOOK` variable)
- Only vault-free playbooks run in lint/syntax (bootstrap, docker, monitoring); full validation in deploy job

### Phase 6 — Monitoring
- Uptime Kuma (louislam/uptime-kuma:latest) on `traefik_web` network
- Health check via container exec
- Accessible at https://status.educollege.in

### Phase 7 — Backups
- Two cron jobs running as root:
  - **Database backup** — nightly at 2:00 AM UTC: `mariadb-dump` with gzip, 14-day retention
  - **Volume backup** — nightly at 2:30 AM UTC: tars EspoCRM volumes (data, custom, client), 14-day retention
- Scripts at `/opt/backup/db-backup.sh` and `/opt/backup/volume-backup.sh`
- Logs at `/var/log/espocrm-backup.log`

### Phase 8 — EspoCRM
- Docker Compose stack:
  - **espocrm** (espocrm/espocrm:8.4) — Apache/PHP, health check via curl to /api/v1/
  - **espocrm-db** (mariadb:11.4) — tuned: 128M max packet, 256M buffer pool, utf8mb4
  - **espocrm-redis** (redis:7-alpine) — AOF persistence, 128MB max memory, allkeys-lru eviction
- Volumes: espocrm_data, espocrm_custom, espocrm_client, espocrm_db_data, espocrm_redis_data
- **Known issue — container recreation can crash-loop (confirmed root cause, Oct 2026 incident):** `/var/www/html` itself is NOT a named volume — only its `data/`, `custom/`, and `client/` subdirectories are. The image ships `/var/www/html` completely empty; `docker-entrypoint.sh` only copies the application code in from `/usr/src/espocrm` when its `installationType()` check decides to (`install`/`reinstall`/`upgrade`). That check reads `data/config.php`'s `isInstalled` flag and version — if it says "already installed, same version" (true for a long-lived `data` volume), the entrypoint takes the `skip` path and copies **nothing**, even though this specific container has never had the code copied into its own (non-persisted) filesystem layer. Any deploy that forces Docker to recreate the `espocrm` container (e.g. an env var change, including `espocrm_smtp_*`) can trigger this — site goes down with `docker logs espocrm` showing `require_once(/var/www/html/bootstrap.php): Failed to open stream` on a tight restart loop. **This is unrelated to real data loss — `data`/`custom`/`client` content is untouched, only the ephemeral application code is missing.** See the non-destructive fix in Troubleshooting below; do not use the old "remove volumes and redeploy" approach on a live instance with real data — see why under Troubleshooting.
- **Job queue:** `docker exec espocrm php cron.php` is scheduled every minute via root's crontab (task `espocrm-cron` in `roles/espocrm/tasks/main.yml`). Without this, EspoCRM's internal job queue (lead-assignment notification emails, etc.) just accumulates as "Pending" forever — the Admin panel will show "Scheduled jobs are not running" if this cron entry is ever missing. Logs: `/var/log/espocrm-cron.log`.

---

## Vault Secrets

File: `vault/secrets.yml` (encrypted with `ansible-vault`)

| Variable | Purpose |
|---|---|
| `espocrm_db_password` | MariaDB user password |
| `espocrm_db_root_password` | MariaDB root password |
| `espocrm_admin_user` | EspoCRM admin username (default: admin) |
| `espocrm_admin_password` | EspoCRM admin password |
| `espocrm_smtp_*` | SMTP config for outgoing mail — server/port/username/password/security. **Must be set for EspoCRM's native notification emails (e.g. lead-assignment alerts) to work at all** — these default to empty strings in `roles/espocrm/templates/docker-compose.yml.j2`, and an unset vault entry silently deploys with no SMTP relay configured (Admin → Outbound Emails will show a blank Server field). Currently wired to the project's SMTP2GO account (`mail.smtp2go.com`, port 2525, TLS) — see SMTP2GO's Sending → SMTP Users for the `educollege.in` user. |
| `traefik_dashboard_auth` | Basic auth hash for Traefik dashboard |
| `cloudflare_email` | Cloudflare account email |
| `cloudflare_api_token` | Cloudflare API token (Zone:DNS:Edit) |

**Vault password:** stored in the team password manager only — **never write the literal password in this file or any committed file again.** A previous version of this README documented the password in plain text here; it leaked (see commit `88ce59a`), was rotated, the rotation was never re-documented, and the password was later lost entirely (recovered Oct 2026 — see "Vault password recovery" under Troubleshooting). Do not repeat that mistake: if you rotate this password, update the team password manager and the `ANSIBLE_VAULT_PASSWORD` GitHub secret, and stop there.

Encrypt: `ansible-vault encrypt vault/secrets.yml`  
Edit: `ansible-vault edit vault/secrets.yml --vault-password-file <(echo 'the password from your password manager')`  
View: `ansible-vault view vault/secrets.yml --vault-password-file <(echo 'the password from your password manager')`

---

## GitHub Configuration

### Environment: `production`

**Secrets (Settings → Environments → production → Environment secrets):**

| Secret | Value |
|---|---|
| `SSH_PRIVATE_KEY` | Contents of `~/.ssh/id_ed25519_hostinger_crm` |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan 200.97.165.13` output |
| `SSH_KEY_PASSPHRASE` | Passphrase for the SSH key |
| `ANSIBLE_VAULT_PASSWORD` | Current vault password — see team password manager, not written here (see Vault Secrets above for why) |

**Variables (Settings → Environments → production → Environment variables):**

| Variable | Value |
|---|---|
| `DOMAIN` | `crm.educollege.in` |
| `BASE_DOMAIN` | `educollege.in` |
| `DISCORD_WEBHOOK` | Discord webhook URL (optional) |

---

## EspoCRM

### Access
- URL: https://crm.educollege.in
- Login: `admin` / (password in vault → `espocrm_admin_password`)
- The 418 HTTP status from curl is normal — EspoCRM's CSRF protection rejects non-browser requests

### Health Check
- Container health: `curl -s -o /dev/null http://localhost/api/v1/` (returns 0 if Apache is responding)
- API check: `curl -s http://localhost/api/v1/` (returns 401 = auth required = healthy)

### Database
- Direct access: `docker exec -it espocrm-db mariadb -u espocrm -p espocrm`
- Root access: `docker exec -it espocrm-db mariadb -u root -p`

---

## Backup & Restore

### List backups
```bash
ssh deploy@200.97.165.13 'ls -lh /opt/backup/database/ /opt/backup/volumes/'
```

### Manual backup
```bash
ssh deploy@200.97.165.13 'sudo /opt/backup/db-backup.sh'
ssh deploy@200.97.165.13 'sudo /opt/backup/volume-backup.sh'
```

### Restore database
```bash
# 1. Copy backup to VPS
scp espocrm_TIMESTAMP.sql.gz deploy@200.97.165.13:/tmp/

# 2. Restore
ssh deploy@200.97.165.13 '
  gunzip -c /tmp/espocrm_TIMESTAMP.sql.gz | \
  docker exec -i espocrm-db mariadb -u espocrm -p espocrm
'
```

### Restore volumes
```bash
ssh deploy@200.97.165.13 '
  docker run --rm \
    -v espocrm_data:/restore \
    -v /opt/backup/volumes:/backup:ro \
    alpine tar xzf /backup/espocrm_data_TIMESTAMP.tar.gz -C /restore
'
```

---

## Troubleshooting

### SSH connection fails
```bash
# Re-add key to agent
eval $(ssh-agent -s)
ssh-add ~/.ssh/id_ed25519_hostinger_crm
ssh deploy@200.97.165.13 'echo ok'
```

### Container restart loop (502 / Bad Gateway)
Check logs: `docker logs espocrm`

If you see `require_once(/var/www/html/bootstrap.php): Failed to open stream` on a tight restart loop — **this is the application code missing from the container, not corrupted data.** See the root-cause explanation in Phase 8 above. Confirmed during the Oct 2026 incident (triggered by a deploy that changed `espocrm_smtp_*`, forcing container recreation).

**Do NOT run the old fix below on a live instance with real data — it deletes `data`/`custom`/`client`, which holds `config.php`, uploaded files, and any custom code (e.g. `custom/Espo/Custom/Controllers/*`):**
```bash
# DESTRUCTIVE — data loss on a live instance. Only acceptable on a fresh,
# never-used-in-production install where these volumes hold nothing real.
cd /opt/espocrm && docker compose down
docker volume rm espocrm_data espocrm_custom espocrm_client
docker compose up -d
```

**Safe fix instead** — copies only the missing application code from a fresh instance of the same image into the live container; does not touch the database, does not touch `data`/`custom`/`client` content, does not reinstall or reset anything:
```bash
set -e
docker create --name espocrm-src-tmp espocrm/espocrm:8.4 >/dev/null
rm -rf /tmp/espocrm_src; mkdir -p /tmp/espocrm_src
docker cp espocrm-src-tmp:/usr/src/espocrm/. /tmp/espocrm_src/
docker rm espocrm-src-tmp >/dev/null
docker cp /tmp/espocrm_src/. espocrm:/var/www/html/
docker exec --user root espocrm chown -R www-data:www-data /var/www/html 2>&1 || true
rm -rf /tmp/espocrm_src
sleep 15
docker ps -a --filter name=espocrm   # expect "Up ... (healthy)"
```
If `chown` errors with "Container is restarting" the first time, that's fine — the `docker cp` already landed the files, so the next automatic restart attempt should succeed; re-run just the `chown` line once `docker ps` shows the container as `Up`.

**To prevent this going forward:** any future deploy that changes an env var on the `espocrm` service (anything under `environment:` in `roles/espocrm/templates/docker-compose.yml.j2`, which includes all `espocrm_smtp_*` vault values) will force a container recreation and can trigger this. Expect a short outage (~1-2 min to apply the fix above) immediately after any such deploy, and verify the site loads before considering the deploy done.

### Vault password lost / `ansible-vault` says "Invalid vault password"
Confirmed recoverable without resetting any live credential, as long as the `ANSIBLE_VAULT_PASSWORD` GitHub Actions secret still works (it decrypts for every CI deploy, so if deploys have recently succeeded, it's still good):

1. Generate a new password (e.g. `openssl rand -base64 32`), save it in the password manager.
2. Add it as a new GitHub secret `ANSIBLE_VAULT_PASSWORD_NEW` under the `production` environment.
3. Temporarily add a `workflow_dispatch`-only job to `.github/workflows/deploy.yml` that runs `ansible-vault rekey vault/secrets.yml --vault-password-file <(old) --new-vault-password-file <(new)` using both secrets, then uploads the re-encrypted `vault/secrets.yml` as a build artifact (not committed automatically — keep a human in the loop for the actual commit). **This job must declare `environment: production`** or GitHub Actions silently resolves the environment-scoped secrets to empty strings instead of erroring, which looks identical to "the password is wrong" (this cost real time during the Oct 2026 recovery — don't repeat it).
4. Trigger it manually (Actions → Run workflow), download the artifact, replace your local `vault/secrets.yml` with it, verify with `ansible-vault view ... --vault-password-file <(echo 'new password')`.
5. Commit, update `ANSIBLE_VAULT_PASSWORD` to the new value, delete `ANSIBLE_VAULT_PASSWORD_NEW`, remove the temporary job.

If `ANSIBLE_VAULT_PASSWORD` itself no longer decrypts either, the vault is genuinely unrecoverable — the fallback is rebuilding it from scratch with fresh values (new DB password, new admin password, new Cloudflare token, new Traefik auth, new SMTP creds), applied carefully to avoid locking out live access. Every value currently in the vault can be independently re-set or read from the live system except the DB/admin passwords, which would need a reset via `docker exec espocrm-db mariadb` / EspoCRM's CLI.

### Docker provider errors (Traefik logs)
`client version 1.24 is too old. Minimum supported API version is 1.40`  
This is expected — Docker 29.x enforces API 1.40 minimum. We use file-based routing (not Docker provider), so these errors don't affect functionality. The docker-proxy container and Docker provider were removed.

### SSL issues
- Verify certs: `sudo python3 -c "import json; d=json.load(open('/opt/traefik/letsencrypt/acme.json')); print([c['domain']['main'] for c in d['letsencrypt']['Certificates']])"`
- Check Traefik logs: `sudo cat /opt/traefik/logs/traefik.log | grep -i acme`
- Cloudflare DNS propagation can take 5-15 minutes for new subdomains
- Cloudflare Universal SSL wildcard (`*.educollege.in`) covers ONE level only — use flat subdomains (status.educollege.in, traefik.educollege.in), not sub-subdomains

### Check all containers
```bash
ssh deploy@200.97.165.13 'docker ps --format "table {{.Names}}\t{{.Status}}"'
```

### View cron jobs
```bash
ssh deploy@200.97.165.13 'sudo crontab -l'
```

### View backup logs
```bash
ssh deploy@200.97.165.13 'sudo tail -50 /var/log/espocrm-backup.log'
```

---

## Notes & Gotchas

1. **Cloudflare proxy + SSL:** DNS challenge is required (HTTP challenge doesn't work through Cloudflare proxy). The Cloudflare API token needs Zone:DNS:Edit permission.
2. **Cloudflare wildcard limitation:** `*.educollege.in` covers `crm.educollege.in` but NOT `status.crm.educollege.in`. Use flat subdomains.
3. **Docker 29.x incompatibility:** Traefik's Docker provider doesn't work with Docker ≥29.x (API version mismatch). File-based routing is the workaround.
4. **Vault file must be encrypted before pushing** — contains real passwords and API tokens.
5. **SSH key passphrase** is required for GitHub Actions — the workflow decrypts it via `ssh-add` with stdin.
6. **EspoCRM first deploy** requires clean volumes. Stale volumes from failed installs cause crash loops. **This same crash signature can also happen on a live, previously-working instance** whenever a deploy forces container recreation — see Phase 8 and "Container restart loop" under Troubleshooting for the confirmed root cause and non-destructive fix (do not reach for "remove volumes" on a live instance).
7. **The 418 HTTP status** from curl is EspoCRM's CSRF protection — not an error. Browsers get HTTP 200.
8. **Traefik dashboard auth** is auto-generated on first deploy. Password saved at `/opt/traefik/.dashboard-password` on the VPS.
9. **Permissions:** `/opt/traefik/letsencrypt/acme.json` must be 0600. The deploy creates it with correct permissions.
10. **"New Lead Received" team notification emails — two independent mechanisms send these, both through SMTP2GO, correcting an earlier (wrong) assumption that this was Make.com-only:**
    - **Primary (confirmed Oct 2026):** a native EspoCRM **Formula script** at Admin → Entity Manager → Lead → Formula → "Before Save Custom Script" (`#Admin/entityManager/formula&scope=Lead&type=beforeSaveCustomScript`). On `entity\isNew()`, it builds an Email record (`to: avnish2008@gmail.com;eduplorleads@gmail.com`, subject `New Lead Received: <name>`) and sends it via `ext\email\send()` — EspoCRM's own native mail path, meaning **it depends directly on `espocrm_smtp_*` being correctly set** (see Vault Secrets above) and on the cron job running (see Job queue above). If these emails stop, check Admin → Outbound Emails (Server populated? "Send Test Email" working?) and Admin → Scheduled Jobs first — not Make.com.
    - **Secondary, separate recipient:** a native EspoCRM Webhook (Admin → Webhooks, event `Lead.create`, API user `lpu-ad-page`) posts to an external Make.com (Integromat) scenario (`https://hook.eu1.make.com/34qoyhp7aefdumrjbb6p8cw3381p7hk4`), which calls SMTP2GO independently and appears to be what delivers to a third recipient (`ankitpandey.bdm@gmail.com`) not present in the Formula script above. If only that third recipient stops receiving mail, check the Make.com scenario's run history (it auto-pauses after repeated errors) — EspoCRM's webhook/API user showing "active" does not mean the Make.com side is actually running.
    - **SMTP2GO account:** free plan, 1,000 emails/month cap (resets ~end of month — check Dashboard for exact date). If volume grows, both mechanisms above will silently stop delivering once the cap is hit, with the same symptoms as a broken SMTP config. Upgrading the plan, or self-hosting an SMTP server, were both considered — self-hosting was rejected due to deliverability risk (shared-hosting IPs get flagged by Gmail/Outlook with no sending reputation); a cheap managed relay (e.g. Amazon SES) is the better fallback if SMTP2GO's cap becomes a real constraint.

11. **Diagnosing "CRM notifications/emails aren't working" — check in this order** (confirmed effective during the Oct 2026 incident):
    1. Admin → Outbound Emails — is `SMTP → Server` populated? Use "Send Test Email."
    2. Admin → Scheduled Jobs — is there a red "Scheduled jobs are not running" banner on the Admin home page? Are recent `Process Job Queue *` entries showing `Success` with a real `Executed At` timestamp (not stuck `Pending`)?
    3. Admin → Entity Manager → Lead → Formula (Before Save) — is the notification script in note 10 above still present/unmodified?
    4. Admin → Webhooks — is the `Lead.create` webhook to Make.com still `Is Active`? (Doesn't confirm Make.com itself is working — just that EspoCRM is still firing it.)
    5. SMTP2GO dashboard → Reports → Activity — are emails actually showing `Delivered`, and is the monthly volume cap close to being hit?
    6. If SMTP shows configured but nothing sends: check `docker logs espocrm` for SMTP connection errors, and confirm the cron job (item 2) is actually running — a correct SMTP config with a dead job queue still won't send anything.
