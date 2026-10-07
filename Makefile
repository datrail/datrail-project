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

# Deletes everything the stack created: its containers, including ones only
# an older docker-compose.yml declared; every volume labelled with this
# Compose project, including an older version's (`captures`, `raildash-db`),
# so RailDash's database and token go too; and the two built images.
clean:
	docker compose down -v --remove-orphans --rmi all
	project=$$(docker compose config | sed -n 's/^name: //p') && \
	test -n "$$project" && \
	docker volume ls -q --filter "label=com.docker.compose.project=$$project" \
	  | xargs -r docker volume rm

config:
	docker compose config --quiet

# The CI acceptance run. Privileged; use a disposable host.
test:
	COMPOSE_PROJECT_NAME=$${COMPOSE_PROJECT_NAME:-datrail-test} \
	EVIDENCE_DIR=$${EVIDENCE_DIR:-$$(mktemp -d)} \
	bash tests/stack-acceptance.sh
