.PHONY: ping bootstrap docker deploy

ping:
	ansible all -m ping

bootstrap:
	ansible-playbook playbooks/bootstrap.yml

docker:
	ansible-playbook playbooks/docker.yml

deploy:
	ansible-playbook playbooks/site.yml
