---
name: fix-espocrm-crash-loop
description: Fix the EspoCRM container crash-loop / 502 Bad Gateway that follows a deploy changing any env var on the espocrm service (most commonly espocrm_smtp_* in the vault). Use when crm.educollege.in returns a Cloudflare 502, or `docker ps` shows the espocrm container "Restarting", or `docker logs espocrm` shows `require_once(/var/www/html/bootstrap.php): Failed to open stream` on a tight loop.
---

# Fix EspoCRM container crash-loop (502 Bad Gateway)

## Symptoms
- `https://crm.educollege.in` returns Cloudflare "Bad gateway" (Error 502),
  with Cloudflare's own status page showing "Host: Error" (Cloudflare itself
  is reachable, the origin is not).
- `docker ps -a --filter name=espocrm` shows `Restarting (255) ... ago` with
  a climbing `RestartCount`, while `espocrm-db` and `espocrm-redis` stay
  healthy and unaffected.
- `docker logs espocrm` repeats:
  ```
  PHP Fatal error:  Uncaught Error: Failed opening required
  '/var/www/html/bootstrap.php' (include_path=...) in Command line code:2
  ```
- Typically appears within ~1 minute of a `docker compose up -d` that
  changed something under `environment:` for the `espocrm` service in
  `roles/espocrm/templates/docker-compose.yml.j2` — e.g. a vault edit to
  `espocrm_smtp_*` that gets applied via the GitHub Actions deploy job.

## Root cause (confirmed, Oct 2026 incident)
`/var/www/html` is **not** a named Docker volume — only its `data/`,
`custom/`, and `client/` subdirectories are (`espocrm_data`, `espocrm_custom`,
`espocrm_client`). The `espocrm/espocrm:8.4` image ships `/var/www/html`
completely empty; `docker-entrypoint.sh` only copies the application code in
from `/usr/src/espocrm` when its `installationType()` function decides to
run `install`/`reinstall`/`upgrade`. That function reads `data/config.php`'s
`isInstalled` flag and recorded version — on a long-lived production
instance those say "already installed, same version", so it takes the
`skip` branch and copies **nothing**.

That's correct for a container that's just restarting in place. It's wrong
for a **brand-new** container — which is exactly what `docker compose up -d`
creates whenever an env var changes, even though the named volumes (and
therefore `data/config.php`) persist across the recreation. The new
container inherits a legitimate "already installed" data volume but has
never had the actual PHP application code copied into its own (non-
persisted) filesystem layer.

**Confirm this diagnosis before applying the fix** — don't skip this,
the same crash text is also the documented symptom of genuinely stale/
corrupted volumes from a *failed first install*, which is a different
situation (that one *is* a reason to consider removing volumes, but only
on an install that never held real data):
```bash
ssh deploy@200.97.165.13 'docker exec espocrm-db mariadb -u root -p -e "SELECT 1"'  # DB still fine?
ssh deploy@200.97.165.13 'docker run --rm -v espocrm_data:/d alpine ls -la /d/'      # data/ volume populated and recently touched?
```
If the DB responds and `data/` has a populated, recently-modified
`config.php`, this is the crash-loop described here, not a failed install.

## Fix — safe, non-destructive, verified working
Copies only the missing application code from a fresh instance of the same
image into the live container. Does **not** touch the database, does
**not** touch `data`/`custom`/`client` volume content, does **not** run any
install/reinstall/upgrade routine, does **not** reset config, admin login,
or customizations.

```bash
ssh deploy@200.97.165.13
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

If `chown` errors with "Container is restarting", that's expected on the
first pass — the `docker cp` already landed the files before that line ran,
so the next automatic restart attempt succeeds on its own; re-run just the
`chown` line once `docker ps` shows the container `Up`.

**Verify fully fixed, not just "Up":**
1. `docker ps -a --filter name=espocrm` shows `Up X (healthy)`, not just `Up`.
2. Load `https://crm.educollege.in` in a browser — full UI renders, no 502.
3. If the crash was triggered by an SMTP/vault change, check
   `Admin → Outbound Emails` shows the expected values and "Send Test
   Email" actually delivers (cross-check in SMTP2GO's Activity log).

## Never do this on a live instance
```bash
# DESTRUCTIVE — deletes data/config.php, uploaded files, and any custom
# code under custom/Espo/Custom/. Only acceptable on a fresh install that
# has never held real production data.
cd /opt/espocrm && docker compose down
docker volume rm espocrm_data espocrm_custom espocrm_client
docker compose up -d
```
This is EspoCRM's own documented fix for "stale volumes from a failed
install" and is still correct for that specific case — but it is the wrong
fix for a crash-loop on a previously-working instance, which is what this
skill covers. If genuinely unsure which situation you're in, confirm via
the DB/volume checks above before choosing a fix.

## Prevention
Any deploy that changes an env var under `environment:` for the `espocrm`
service (`roles/espocrm/templates/docker-compose.yml.j2` — this includes
every `espocrm_smtp_*` vault value) forces Docker to recreate the
container and can trigger this. After any such deploy, expect a short
outage and verify the site loads before considering the deploy done; don't
assume a green CI run means the site is actually up.

## See also
- `~/company-infra/README.md` → Phase 8 and "Container restart loop" under
  Troubleshooting (full incident writeup).
- Same repo's "Vault password lost" troubleshooting entry if the crash was
  triggered while also recovering a lost vault password.
