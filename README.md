# Company Infrastructure

## Purpose

Production infrastructure for the company CRM.

## Stack

- Ubuntu 24.04
- Ansible
- Docker
- Traefik
- EspoCRM
- MariaDB
- Redis
- Cloudflare

## Server

Provider: Hostinger

## Deployment

```bash
ansible-playbook playbooks/site.yml


crm-infrastructure/
│
├── README.md                    # Project overview
├── LICENSE                       # Optional
├── .gitignore
├── ansible.cfg
├── Makefile                      # (Later) Common commands
│
├── inventory/
│   ├── production.ini
│   ├── staging.ini               # Later
│   │
│   ├── group_vars/
│   │   ├── all.yml
│   │   └── production.yml
│   │
│   └── host_vars/
│       └── crm.yml               # Later if host-specific variables exist
│
├── playbooks/
│   ├── site.yml                  # Master playbook
│   ├── bootstrap.yml
│   ├── docker.yml
│   ├── monitoring.yml
│   ├── backup.yml
│   └── cleanup.yml
│
├── roles/
│   ├── common/
│   ├── ssh/
│   ├── firewall/
│   ├── fail2ban/
│   ├── docker/
│   ├── traefik/
│   ├── monitoring/
│   ├── backup/
│   └── espocrm/
│
├── docker/
│   ├── traefik/
│   ├── espocrm/
│   ├── monitoring/
│   ├── uptime-kuma/
│   └── test-app/
│
├── templates/
│
├── files/
│
├── scripts/
│
├── docs/
│   ├── architecture.md
│   ├── server.md
│   ├── deployment.md
│   ├── backup.md
│   ├── restore.md
│   ├── networking.md
│   ├── security.md
│   └── troubleshooting.md
│
├── vault/
│   ├── .gitkeep
│   └── secrets.yml
│
└── tests/
    └── ansible/
```bash
