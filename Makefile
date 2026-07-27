.PHONY: ping bootstrap docker traefik espocrm monitoring backup deploy cleanup lint

# Vault password file — create with: echo "espocrm-vault-2025!" > .vault_pass
VAULT_PASS_FILE := $(wildcard .vault_pass)
VP := $(if $(VAULT_PASS_FILE),--vault-password-file $(VAULT_PASS_FILE),)

ping:
	ansible all -m ping

bootstrap:
	ansible-playbook playbooks/bootstrap.yml

docker:
	ansible-playbook playbooks/docker.yml

traefik:
	ansible-playbook playbooks/traefik.yml $(VP)

espocrm:
	ansible-playbook playbooks/espocrm.yml $(VP)

monitoring:
	ansible-playbook playbooks/monitoring.yml

backup:
	ansible-playbook playbooks/backup.yml $(VP)

deploy:
	ansible-playbook playbooks/site.yml $(VP)

cleanup:
	ansible-playbook playbooks/cleanup.yml $(VP)

lint:
	ansible-lint playbooks/bootstrap.yml playbooks/docker.yml playbooks/monitoring.yml roles/

syntax:
	@for pb in playbooks/*.yml; do echo "=== $$pb ==="; ansible-playbook "$$pb" --syntax-check $(VP) || exit 1; done
	@echo "All playbooks: OK"

install-collections:
	ansible-galaxy collection install -r requirements.yml

test-ssh:
	ansible all -m ping -vvv
