---
name: diagnose-espocrm-notifications
description: Diagnose why EspoCRM (crm.educollege.in) isn't sending lead/notification emails - "New Lead Received" alerts not arriving, lead-assignment emails missing, or the Admin panel showing "Scheduled jobs are not running". Use when asked to investigate or fix CRM email/notification delivery, or why a specific recipient stopped getting lead emails.
---

# Diagnose EspoCRM notification/email issues

## Two independent mechanisms send "New Lead Received" emails — know which one broke

Don't assume a single cause. Both go through the same SMTP2GO account but
are otherwise unrelated:

1. **Primary — native EspoCRM Formula script.** Admin → Entity Manager →
   Lead → Formula → "Before Save Custom Script"
   (`#Admin/entityManager/formula&scope=Lead&type=beforeSaveCustomScript`).
   On `entity\isNew()` it builds an Email record (`to:
   avnish2008@gmail.com;eduplorleads@gmail.com`) and sends it via
   `ext\email\send()` — EspoCRM's own native mail path. This depends
   directly on:
   - `Admin → Outbound Emails` SMTP config being correctly set (vault key
     `espocrm_smtp_*` in `company-infra`'s `vault/secrets.yml`)
   - the job-queue cron actually running (see step 2 below)
2. **Secondary, separate recipient — Make.com webhook.** Admin → Webhooks,
   event `Lead.create`, API user `lpu-ad-page`, posts to
   `https://hook.eu1.make.com/34qoyhp7aefdumrjbb6p8cw3381p7hk4`. That
   external Make.com scenario calls SMTP2GO independently and is what
   delivers to a third recipient (`ankitpandey.bdm@gmail.com`) not present
   in the Formula script above.

If only `ankitpandey.bdm@gmail.com` stopped receiving mail, the problem is
in Make.com, not EspoCRM — check that scenario's run history directly
(Make.com auto-pauses a scenario after repeated execution errors).
EspoCRM's webhook/API user showing "active" does **not** confirm the
Make.com side is actually running; it only confirms EspoCRM is still
firing the webhook.

If all recipients stopped, or the Admin panel shows a notifications
problem generally, work through the checklist below in order.

## Diagnosis checklist (in order — confirmed effective, Oct 2026 incident)

1. **`Admin → Outbound Emails`** — is `SMTP → Server` populated (not blank)?
   Use the "Send Test Email" button; cross-check delivery in SMTP2GO's
   Reports → Activity log (should show `Delivered`, not stuck or missing).
   A blank Server field with real `espocrm_smtp_*` values apparently set
   in the vault usually means the vault's values were never actually
   deployed, or were deployed with empty strings — check the live
   container directly:
   ```bash
   ssh deploy@200.97.165.13 "docker inspect espocrm --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i smtp"
   ```
2. **`Admin` home page** — red "Scheduled jobs are not running" banner?
   Then `Admin → Scheduled Jobs` — are recent `Process Job Queue *`
   entries `Success` with a real `Executed At` timestamp (not stuck
   `Pending`)? EspoCRM needs `docker exec espocrm php cron.php` running on
   a schedule (every minute, via root's crontab, task `espocrm-cron` in
   `roles/espocrm/tasks/main.yml`) to process anything — a correct SMTP
   config with a dead job queue still sends nothing for jobs that funnel
   through the queue. (The Formula script in this doc calls
   `ext\email\send()` directly rather than queuing, so it's not blocked
   by this specifically — but lead-*assignment* notifications and most
   other native EspoCRM notifications are.)
3. **`Admin → Entity Manager → Lead → Formula`** (Before Save) — is the
   notification script described above still present and unmodified?
4. **`Admin → Webhooks`** — is the `Lead.create` → Make.com webhook still
   `Is Active`? If not, EspoCRM itself stopped firing it (fixable in
   EspoCRM). If active but Make.com still isn't delivering, the problem is
   entirely on Make.com's side — not fixable from EspoCRM/this repo.
5. **SMTP2GO dashboard** (`app-us.smtp2go.com`) → Reports → Activity /
   Dashboard chart — are emails actually showing `Delivered`? Check the
   monthly volume cap too: free plan is capped at 1,000 emails/month
   (resets monthly — exact date shown on the Dashboard). If the cap is
   hit, sends start failing with the same symptoms as a broken SMTP
   config, silently, with no obvious error in EspoCRM itself.
6. **If SMTP looks configured but nothing sends:**
   `ssh deploy@200.97.165.13 'docker logs espocrm --tail 100'` for SMTP
   connection errors (auth failure, wrong port, TLS negotiation failure).
   If the site is returning a 502 / the container is crash-looping instead
   of just failing to send, that's a different, unrelated problem — see
   the `fix-espocrm-crash-loop` skill.

## Where the SMTP credentials actually live
`company-infra`'s `vault/secrets.yml`, keys `espocrm_smtp_server`,
`espocrm_smtp_port`, `espocrm_smtp_security`, `espocrm_smtp_username`,
`espocrm_smtp_password` — currently wired to the SMTP2GO account's
`educollege.in` SMTP user (`mail.smtp2go.com`, port 2525, TLS). Edit via
`ansible-vault edit vault/secrets.yml` (see README "Vault Secrets" section
for the password — never in this file or any committed file). A deploy
after editing the vault **will** recreate the `espocrm` container and can
trigger the crash-loop in `fix-espocrm-crash-loop` — expect that and verify
the site loads afterward.

## Don't assume Make.com by default
This whole mechanism was previously (incorrectly) documented as "Make.com
sends these emails." That was wrong for 2 of the 3 recipients — the
Formula script above is the real primary path and depends on this repo's
own `espocrm_smtp_*` config. Check the Formula script and Outbound Emails
config *before* spending time investigating Make.com, unless the symptom
is specifically isolated to the one Make.com-only recipient.
