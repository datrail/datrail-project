# Shortcuts for docker-compose.yml; every target is one `docker compose`
# command, so nothing here is needed to run the stack.
.PHONY: up update logs down clean config test

up:
	docker compose up -d

# Build both images from the latest default branches under local names, then
# restart on them. Without the names, docker-compose.yml's pinned published
# tags would label the build (INSTALL.md, "Images").
update:
	RAILMON_IMAGE=datrail-railmon:local RAILDASH_IMAGE=datrail-raildash:local \
	  docker compose up -d --build

logs:
	docker compose logs -f --tail=50

# With the opt-in openshell profile too, so its collector, which mounts
# RailDash's volume, is stopped whether or not the stack was started with it.
down:
	COMPOSE_PROFILES=openshell docker compose down

# Deletes everything the stack created: its containers, including ones only
# an older docker-compose.yml declared; every volume labelled with this
# Compose project, including an older version's (`captures`, `raildash-db`),
# so RailDash's database and token go too; and the stack's two images,
# the pinned published ones and the local names `update` builds. The
# openshell profile as in `down`: a collector left running would hold
# RailDash's volume.
clean:
	COMPOSE_PROFILES=openshell docker compose down -v --remove-orphans --rmi all
	docker image rm datrail-railmon:local datrail-raildash:local 2>/dev/null || true
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
