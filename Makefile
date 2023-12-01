# GNU Make
#CONTEXT := $(shell echo placeholder1)
#VAULT_IP := $(shell echo placeholder2)

.PHONY: up down init show-ports
up: create-pki compose-up create-steady-state
down: compose-down delete-secrets delete-recovery-files


# helpers
show-ports:
	docker ps --format=json | jq -sr '[ .[] | [.Names,.ID,.Ports] ] | sort | .[] | @tsv'


# setup rules
create-pki:
	cd scripts ; ./init-pki.sh

compose-up:
	docker compose up -d

create-steady-state:
	scripts/init-steady-state.sh


# clean-up rules
compose-down:
	docker compose down
	docker volume prune -f

delete-secrets:
	rm -rv tls secrets/init.json

delete-recovery-files:
	rm -rv secrets/init-backup.json snapshots
