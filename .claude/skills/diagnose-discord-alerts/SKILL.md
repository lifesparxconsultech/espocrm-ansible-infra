---
name: diagnose-discord-alerts
description: Diagnose why a Discord alert isn't firing - CI/CD deploy success/failure pings missing, the VPS "VPS Health" post (every 3h) missing, or the daily "Database Backup Complete" post missing. Use when asked to investigate or fix Discord notifications/alerts not working for this repo's CI/CD or the crm-server VPS cron jobs.
---

# Diagnose missing Discord alerts

There are **three independent alert paths**. They share no code and fail
independently, but two of them share one credential (the vault's
`discord_webhook`), so they tend to break and get fixed together. Work out
which path(s) are actually silent before changing anything.

| Path | Trigger | Webhook source | Logs its own failure? |
|---|---|---|---|
| CI/CD deploy notify | push/dispatch to `deploy.yml` | GH env secret `DISCORD_WEBHOOK` | Yes — in the Actions run log |
| VPS health check | cron, every 3h | vault `discord_webhook`, baked into `health-check.sh` | No — check Discord directly |
| Daily DB backup | cron, 02:00 UTC | vault `discord_webhook`, baked into `db-backup.sh` | Yes — `/var/log/espocrm-backup.log` |

Quiz/HRMS monitor bots (`quiz-monitor.sh`, `hrms-monitor.sh`) are a
**different system** (educollege-hrms project, not this repo) reading
separate webhook files (`/opt/backup/discord-webhook`,
`/opt/backup/hrms-webhook`) — their continuing to post is not evidence
that the vault's `discord_webhook` is fine.

## 1. CI/CD deploy notify never fires

`gh run list --limit 5` in this repo — if `Notify Discord` shows
`skipped` with ~0s runtime on every run, the job's `if:` condition isn't
resolving true, regardless of deploy success/failure. Two root causes,
both hit in the same Oct 2026 incident:

- **Context mismatch:** the workflow checked `vars.DISCORD_WEBHOOK` while
  the value is stored as an environment **secret**. `vars.*` and
  `secrets.*` are separate GitHub Actions stores even with an identical
  name — reading the wrong one silently resolves to `''`, no error
  anywhere. Must be `secrets.DISCORD_WEBHOOK`.
- **Missing environment declaration:** an environment-scoped secret is
  only visible to a job that itself declares `environment: production`.
  The `deploy` job had it; `notify` didn't — so even the right context
  name resolves to empty without this.

To confirm a fix actually worked, don't just check the job went green —
check what it actually sent:
```bash
gh run view <run-id> --log | grep -A20 "Send success notification"
```
A healthy run shows the `curl` command and nothing after it. A dead
webhook shows Discord's own error body right after the command block
(see section 3). An unreadable secret (still broken) shows the job
running against an empty URL — `curl` to `""` fails immediately, visible
in the log as a curl error rather than a Discord JSON error.

## 2. VPS health check / DB backup go silent together

Both templated from the same vault var on deploy, so check them together.

```bash
ssh crm-server 'sudo tail -60 /var/log/espocrm-backup.log'
```
`db-backup.sh` logs its own curl response inline — a line like
`{"message":"Unknown Webhook","code":10015}` right after a `Backup: ...`
line means the webhook itself is dead. `health-check.sh`'s cron entry has
no output redirect, so it has no log at all — the only symptom is a gap
in the actual Discord channel. Compare the last message's timestamp
against the expected `00:00/03:00/06:00.../21:00 UTC` cadence; anything
missing an expected tick for more than one cycle means it's actually
broken, not just running late.

To force one manually and watch Discord in real time:
```bash
ssh crm-server '/opt/backup/health-check.sh'   # fails: exit=126, Permission denied
```
That failure is **expected**, not the bug — the script is `root`-owned
`0700` (it contains the webhook URL), and the real cron entry runs as
`root`. Use one of:
```bash
ssh root@<vps-ip> '/opt/backup/health-check.sh'   # password auth
ssh crm-server 'sudo /opt/backup/health-check.sh' # if deploy has sudo
```

If the SSH key itself is giving "Permission denied" after a passphrase
prompt, check the passphrase was typed correctly before concluding
anything about the server — ssh gives up on pubkey auth after a few
failed attempts and falls back to password auth (which doesn't exist for
`deploy`), producing a misleading "Permission denied" that looks
server-side but isn't.

## 3. Fixing a dead webhook

Discord webhooks can be deleted/rotated on Discord's side independent of
anything in this repo — don't assume a deploy caused it just because the
timing lines up; two unrelated webhooks (the CI/CD one and the vault one)
went dead within the same ~24h window in the Oct 2026 incident with no
common code change responsible.

**Always verify a replacement webhook live before wiring it into either
config:**
```bash
curl -s -X POST "<new webhook url>" -H "Content-Type: application/json" \
  -d '{"content":"test"}' -w "\nHTTP_STATUS:%{http_code}\n"
# expect HTTP_STATUS:204, and the message actually visible in Discord
```

Then wire it in:
- **CI/CD path:** `gh secret set DISCORD_WEBHOOK --env production --body "<url>"`
- **VPS cron path:** `ansible-vault edit vault/secrets.yml` → update
  `discord_webhook:` → commit + push (this file isn't in `deploy.yml`'s
  path filter, so it won't auto-trigger CI) → manually run
  `gh workflow run deploy.yml -f playbook=backup` (only re-templates
  backup/health-check scripts and cron entries, never touches the
  `espocrm` container — safe to run anytime, doesn't need a maintenance
  window).

Reusing the same webhook URL for both paths is fine and simpler than
tracking two separate ones.

## Never do this while diagnosing

Don't ask for or paste the Ansible vault password, the SSH key
passphrase, or the root SSH password into any shared/logged channel to
"just fix it faster" — the vault password alone unlocks every other
credential in `vault/secrets.yml` (DB passwords, SMTP creds, Cloudflare
API token). Have the person with access run the vault edit / SSH command
themselves and report back the result instead.
