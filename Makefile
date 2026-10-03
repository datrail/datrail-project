# Shortcuts for docker-compose.yml; every target is one `docker compose`
# command, so nothing here is needed to run the stack.
.PHONY: up update logs down clean config test

up:
	docker compose up -d

# Rebuild both images from the latest default branches, then restart.
update:
	docker compose up -d --build

logs:
	docker compose logs -f --tail=50

down:
	docker compose down

# Also deletes the volumes: RailDash's database and the listen record.
clean:
	docker compose down -v

config:
	docker compose config --quiet

# The CI acceptance run. Privileged; use a disposable host.
test:
	COMPOSE_PROJECT_NAME=$${COMPOSE_PROJECT_NAME:-datrail-test} \
	EVIDENCE_DIR=$${EVIDENCE_DIR:-$$(mktemp -d)} \
	bash tests/stack-acceptance.sh
