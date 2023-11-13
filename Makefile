# GNU Make
#CONTEXT := $(shell echo placeholder1)
#VAULT_IP := $(shell echo placeholder2)


.PHONY: up down init show-ports
up: pki-create compose-up steady-state
down: compose-down pki-destroy

show-ports:
	docker ps --format=json | jq -sr '[ .[] | [.Names,.ID,.Ports] ] | sort | .[] | @tsv'


# setup rules
pki-create:
	cd tls ; ./script.sh

compose-up:
	docker compose up -d

steady-state:
	scripts/init-steady-state.sh


# clean-up rules
compose-down:
	docker compose down
	docker volume prune -f

pki-destroy:
	rm -rv tls/{root-ca.cnf,signing-ca.cnf,root-ca,usca,usil,usny,ustx}
