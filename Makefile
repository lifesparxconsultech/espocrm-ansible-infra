.PHONY: ping bootstrap docker traefik espocrm monitoring backup deploy cleanup lint

ping:
	ansible all -m ping

bootstrap:
	ansible-playbook playbooks/bootstrap.yml

docker:
	ansible-playbook playbooks/docker.yml

traefik:
	ansible-playbook playbooks/traefik.yml

espocrm:
	ansible-playbook playbooks/espocrm.yml

monitoring:
	ansible-playbook playbooks/monitoring.yml

backup:
	ansible-playbook playbooks/backup.yml

deploy:
	ansible-playbook playbooks/site.yml

cleanup:
	ansible-playbook playbooks/cleanup.yml

lint:
	ansible-lint playbooks/ roles/

syntax:
	@for pb in playbooks/*.yml; do echo "=== $$pb ==="; ansible-playbook "$$pb" --syntax-check || exit 1; done
	@echo "All playbooks: OK"

install-collections:
	ansible-galaxy collection install -r requirements.yml

test-ssh:
	ansible all -m ping -vvv
