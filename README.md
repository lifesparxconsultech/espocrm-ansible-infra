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
- **Known issue:** First deploy requires clean volumes. If volumes contain stale data from a failed install, EspoCRM will crash-loop. Fix: remove volumes and redeploy.

---

## Vault Secrets

File: `vault/secrets.yml` (encrypted with `ansible-vault`)

| Variable | Purpose |
|---|---|
| `espocrm_db_password` | MariaDB user password |
| `espocrm_db_root_password` | MariaDB root password |
| `espocrm_admin_user` | EspoCRM admin username (default: admin) |
| `espocrm_admin_password` | EspoCRM admin password |
| `espocrm_smtp_*` | SMTP config for outgoing mail |
| `traefik_dashboard_auth` | Basic auth hash for Traefik dashboard |
| `cloudflare_email` | Cloudflare account email |
| `cloudflare_api_token` | Cloudflare API token (Zone:DNS:Edit) |

**Vault password:** `espocrm-vault-2024`  
Encrypt: `ansible-vault encrypt vault/secrets.yml`  
Edit: `ansible-vault edit vault/secrets.yml`

---

## GitHub Configuration

### Environment: `production`

**Secrets (Settings → Environments → production → Environment secrets):**

| Secret | Value |
|---|---|
| `SSH_PRIVATE_KEY` | Contents of `~/.ssh/id_ed25519_hostinger_crm` |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan 200.97.165.13` output |
| `SSH_KEY_PASSPHRASE` | Passphrase for the SSH key |
| `ANSIBLE_VAULT_PASSWORD` | `espocrm-vault-2024` |

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

### Container restart loop
Check logs: `docker logs espocrm`  
If you see `require_once(/var/www/html/bootstrap.php): Failed to open stream`:
```bash
cd /opt/espocrm && docker compose down
docker volume rm espocrm_data espocrm_custom espocrm_client
docker compose up -d
```

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
6. **EspoCRM first deploy** requires clean volumes. Stale volumes from failed installs cause crash loops.
7. **The 418 HTTP status** from curl is EspoCRM's CSRF protection — not an error. Browsers get HTTP 200.
8. **Traefik dashboard auth** is auto-generated on first deploy. Password saved at `/opt/traefik/.dashboard-password` on the VPS.
9. **Permissions:** `/opt/traefik/letsencrypt/acme.json` must be 0600. The deploy creates it with correct permissions.
