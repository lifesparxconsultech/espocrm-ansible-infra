---
name: upgrade-espocrm-php-version
description: Safely upgrade EspoCRM's Docker image tag (and the PHP version bundled inside it) from one version to another. Use when a PHP security advisory requires a newer PHP than the current `espocrm_version` tag bundles, or when EspoCRM itself needs a version bump. Always test the full path on a cloned staging copy first (see Staging clone procedure below) before touching the production container.
---

# Upgrade EspoCRM / PHP version safely

## Why this exists
Oct 2026 incident: a critical, unauthenticated RCE PHP advisory
(CVE-2026-109618/CVE-2026-109619) landed while this CRM was frozen on
PHP 8.2.24, bundled inside the `espocrm/espocrm:8.4` image. That image
tag was last rebuilt by EspoCRM's own maintainers on **2024-10-14** —
over two years stale — because `roles/espocrm/defaults/main.yml`'s
`espocrm_version: "8.4"` pins an old major-version tag, and EspoCRM only
actively rebuilds tags for its *current* major line (checked via Docker
Hub: 9.x/10.x tags rebuild ~daily, old 8.x tags never rebuild again).
**Recreating the container does nothing for PHP staleness if the pinned
tag itself is frozen** — the only fix is bumping `espocrm_version` to a
currently-maintained tag, which means an EspoCRM app-version upgrade,
not just a PHP patch.

## The core rule: never jump more than one version step at a time
EspoCRM's CLI/Docker upgrade mechanism has a hard internal step-count
safety cap. Confirmed by testing on a full clone of production data:

| Jump attempted | Result |
|---|---|
| `8.4 → 9.3` (direct) | **FAILS** — `error: The MAX_UPGRADE_COUNT exceed.` Falls back claiming to restore the old version, but the app is left serving `HTTP 500` until manually fixed. |
| `9.0 → 9.3` (3 minor versions) | **ALSO FAILS** — differently. Silent crash mid dependency-swap, leaves `vendor/` missing a package (e.g. `laminas-servicemanager`) the app needs. DB/config untouched, but the app is broken until re-fixed. |
| `8.4→9.0→9.1→9.2→9.3→10.0` (one step at a time) | **Every single hop succeeded cleanly.** |

The official docs say to run `php command.php upgrade -y` repeatedly
(it does one step, then prompts to run again) rather than targeting a
version far ahead — but the Docker image's entrypoint does not follow
its own advice: it always auto-invokes
`php command.php upgrade -y --toVersion=<the image's own bundled version>`
on container start. You cannot pass it a smaller target. The only lever
you have is **which image tag you swap to** — so swap to the *next*
maintained minor/major tag, never straight to the final target.

## The known entrypoint bug (hits on every single hop, 8.x/9.x only)
`/var/www/html` is not a named volume on 8.x/9.x images — only `data/`,
`custom/`, `client/` are (see [[fix-espocrm-crash-loop]] for the full
root-cause writeup). A brand-new container from *any* image-tag swap
starts with an empty `/var/www/html` except those three mounted dirs.
The entrypoint's upgrade attempt needs `bootstrap.php` to exist before
it can run anything — it doesn't, so every hop needs the manual
code-copy workaround below before the upgrade can even start.

**10.x is architecturally different — this bug does not apply.** The
10.x image bakes the full `application/`+`vendor/` tree directly into
`/var/www/html` at build time. Check before assuming you need the
workaround: `docker exec <container> test -f /var/www/html/bootstrap.php`
— if it's already there on a fresh container, skip straight to waiting
for the upgrade (10.x uses a much faster `migrate` action, not the old
multi-minute `upgrade` CLI walk — see below).

## Step-by-step procedure (per hop, for 8.x/9.x targets)

```bash
TARGET="9.1.9-apache"     # one step up only — confirm this exact tag
                           # exists on Docker Hub first

# 1. Bump the tag and recreate
sed -i "s|espocrm/espocrm:[^\"[:space:]]*|espocrm/espocrm:${TARGET}|" docker-compose.yml
docker compose pull espocrm && docker compose up -d

# 2. Copy the app code in (works around the bootstrap.php bug above)
docker update --restart=no espocrm        # stops Docker fighting a crash-loop
rm -rf /tmp/src; mkdir -p /tmp/src
docker create --name src-tmp espocrm/espocrm:${TARGET} >/dev/null
docker cp src-tmp:/usr/src/espocrm/. - | \
  tar -xf - -C /tmp/src --exclude="*/docs/*" --exclude="*/doc/*"
docker rm src-tmp >/dev/null
docker cp /tmp/src/. espocrm:/var/www/html/

# 3. If the container is stopped (from the restart-loop), start it; then fix ownership
docker start espocrm 2>/dev/null
sleep 5
docker exec --user root espocrm chown -R www-data:www-data /var/www/html
docker update --restart=unless-stopped espocrm
rm -rf /tmp/src
```

**The `--exclude="*/docs/*"` flags matter.** At least one real image
(`9.2.7-apache`) ships a broken symlink under a vendor package's `docs/`
folder (`vendor/laminas/laminas-mail/docs/book/index.md` → an
out-of-root relative path) that trips Docker's `cp` safety check:
`invalid symlink "..." -> "../../../../../../tmp/..."`. Docs aren't
needed at runtime, so excluding them sidesteps it entirely — needed on
**both** the image→localdisk extraction and the localdisk→container
copy (the bad symlink survives onto local disk too, so skipping the
exclude on only one side still fails).

**Wait — this is slow and silent.** The actual upgrade can take
**4-5 minutes with zero new log output in between**. Do not mistake
this for a hang. Confirm it's genuinely working, not stuck:
```bash
docker exec espocrm ps aux   # look for an active "php command.php upgrade"
                               # or "upgrade-step" process, not just apache2
```
A truly hung process (no child workers, 0% CPU, no progress for 2+
minutes with nothing in `data/.backup/upgrades/<id>/` growing) is the
real failure signal — not silence alone.

**Confirm success before moving to the next hop:**
```bash
docker logs espocrm | grep "Upgrading is finished"
docker exec espocrm curl -s -o /dev/null -w "%{http_code}\n" http://localhost/api/v1/
# expect 401 (healthy, auth required) — never 500
```

**If a hop fails:** re-pull the *previous* known-good tag, re-run the
code-copy procedure for that tag, confirm `/api/v1/` is `401` again
before trying a smaller version gap for the step that failed.

## 10.x-specific procedure (faster, different mechanism)
No code-copy workaround needed — just bump the tag and watch:
```bash
sed -i "s|espocrm/espocrm:[^\"[:space:]]*|espocrm/espocrm:10.0.10-apache|" docker-compose.yml
docker compose pull espocrm && docker compose up -d
docker logs -f espocrm
```
Expected output, usually complete in well under a minute:
```
info: Copying client files.
info: Running "migrate" action.
Cache has been cleared.
Running prepare migrations...
    10.0... DONE
Running after-upgrade migrations...
    10.0... DONE
Completed.
```

## Known side-effects to check after every hop
- **Maintenance Mode gets silently enabled** by the upgrade process at
  some point during the sequence (observed once we reached 10.0.10) and
  is never turned back off automatically. Check
  Administration → Settings → System after the final hop and uncheck it.
- **A Formula script calling `ext\email\send()` directly (not via the
  job queue — see Notes & Gotchas #10 in the main README) throws a hard
  exception that fails the ENTIRE entity save, not just the
  notification, if SMTP is unreachable or misconfigured.** Confirmed
  this is a pre-existing EspoCRM Formula-engine property, identical
  across every version tested (8.4 through 10.0.10) — not something the
  upgrade introduces. But it means: if SMTP2GO is ever down, degraded,
  or over its 1,000/month cap at the exact moment a Lead is created,
  **the lead fails to save entirely** (HTTP 500 back to the submitting
  form), not just a missed notification. Worth a follow-up fix
  independent of this upgrade work: wrap the Formula script's
  `ext\email\send()` call in error handling, or move the notification
  through the job queue instead of calling it synchronously.

## Staging clone procedure (do this before touching production)
1. Pull the latest nightly backup files from the VPS
   (`/opt/backup/database/*.sql.gz`, `/opt/backup/volumes/*.tar.gz`) —
   stream them directly to the test host, don't let a copy sit on a
   laptop (they contain real lead PII).
2. Stand up an isolated `docker compose` stack on the test host —
   separate container/volume/network names, **not** wired into this
   repo's Ansible or inventory (zero chance of ever touching
   production), reachable only on the LAN, no Traefik/Tunnel exposure.
3. Restore the dump + volumes, boot at the **current production image
   tag first**, confirm the restore itself is clean (login, data
   matches) before touching the version.
4. **Neutralize anything that could reach a real person or service
   before testing writes**, directly in the staging DB/config copy —
   this has zero effect on production, these are separate containers:
   - `data/config.php`: blank `smtpServer`, `smtpUsername`,
     `smtpPassword`, `smtpFromAddress`, `outboundEmailFromAddress`, set
     `smtpAuth = false`. Also fix `siteUrl` to the staging URL, and
     `data/config-internal.php`'s `database.host` to the staging DB
     container name (the restored config still points at production's
     internal hostnames).
   - DB `webhook` table: `UPDATE webhook SET is_active=0, deleted=1` for
     any row pointing at a real external service (e.g. the Make.com
     `Lead.create` webhook — see README Notes & Gotchas #10).
   - Check `integration` and `email_account`/`inbound_email` tables for
     any other `enabled=1` rows holding live credentials.
5. Run the per-hop procedure above, one version at a time, verifying
   health after each.
6. Full functional pass before calling it done: Leads/Accounts/
   Opportunities list+detail views, Entity Manager (custom fields
   survived?), the Lead Formula script (still present, unmodified?),
   Scheduled Jobs page, Admin → System Requirements (new PHP version
   shows `Success`), and a real create+delete round-trip on a
   **non-Lead** entity (Lead create will fail in staging specifically
   *because* you neutralized SMTP — see the side-effect note above; test
   writes on Account/Contact instead to isolate "does the write path
   work" from "does this one Formula script's email dependency work").
7. Only then: repeat the identical, now-proven hop sequence against
   production, with a fresh on-demand backup taken immediately before,
   during a low-traffic window, verifying `/api/v1/` returns `401`
   (not `500`) after each hop before proceeding to the next.

## Full tested path (Oct 2026, verified against a 507-lead production clone)
`8.4.2 → 9.0.8-apache → 9.1.9-apache → 9.2.7-apache → 9.3-apache → 10.0.10-apache`

Final verified state: PHP **8.4.27** (patches CVE-2026-109618/109619 and
every PHP CVE since 8.2.24's Sept-2024 release — including CVE-2026-6722,
a CVSS 9.5 unauthenticated SOAP RCE from Aug 2026), EspoCRM **10.0.10**.
All 507 leads, custom fields, the Lead Formula script, and all 10
Scheduled Jobs confirmed intact. Full CRUD confirmed working outside the
SMTP-dependent Formula path noted above.

## See also
- [[fix-espocrm-crash-loop]] — the underlying bootstrap.php-missing bug
  this skill's code-copy workaround exists for; read it first if you hit
  a crash-loop you don't recognize.
- [[diagnose-espocrm-notifications]] — if the Lead Formula script's
  email-send dependency (noted above) is actually breaking lead capture
  in production, not just staging.
- README.md → `## EspoCRM` and `## Notes & Gotchas` #10/#13 for the
  SMTP/webhook architecture this upgrade work surfaced.
