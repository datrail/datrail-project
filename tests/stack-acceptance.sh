#!/usr/bin/env bash
# Bring up docker-compose.yml exactly as the README's quick start does, from
# each component's default branch, and check what a new user should see.
#
# STACK_MODE=own-agent follows INSTALL.md's "Watch your own agent" instead:
# the stack starts without the demo agent, pointed at a container the user
# starts afterwards with `docker run`, which listens on its port at once.
#
# Run only on a disposable host: RailMon's collector and listen probe are
# privileged and share the host's PID namespace.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${COMPOSE_PROJECT_NAME:?set a unique compose project name}"
: "${EVIDENCE_DIR:?set an evidence directory outside the checkout}"
mkdir -p "$EVIDENCE_DIR"

# Faster than a user's defaults, so the drift check fits a CI run.
export SCAN_INTERVAL="${SCAN_INTERVAL:-10}" DEMO_INTERVAL="${DEMO_INTERVAL:-5}"
compose=(docker compose)
mode="${STACK_MODE:-demo}"
case "$mode" in
  demo)
    agent=datrail-demo-agent
    up=(up -d --build)
    ;;
  own-agent)
    # INSTALL.md's command, word for word, plus --build.
    agent=my-agent
    export AGENT_CONTAINER=my-agent COLLECT_TARGET="--comm my-agent-bin"
    up=(up -d --build --scale demo-agent=0)
    ;;
  *) echo "unknown STACK_MODE $mode" >&2; exit 2 ;;
esac

# The stack must start from nothing: leftover volumes would let an earlier
# run's data pass this one.
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]]
[[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]]
[[ -z "$(docker ps -aq --filter "name=^my-agent$")" ]]
project_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME"
}
# What an older version of the stack leaves behind: a volume that the current
# docker-compose.yml no longer declares. `make clean` must remove it.
docker volume create --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
  "${COMPOSE_PROJECT_NAME}_captures" > /dev/null

cleanup() {
  local result=$?
  "${compose[@]}" ps -a > "$EVIDENCE_DIR/services.txt" 2>&1 || true
  "${compose[@]}" logs --no-color > "$EVIDENCE_DIR/services.log" 2>&1 || true
  if [[ $mode == own-agent ]]; then
    # The user's own container: not the stack's, so `make clean` leaves it,
    # and it holds the RailMon image the reset removes.
    docker logs my-agent > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
    docker rm -f my-agent > /dev/null 2>&1 || true
  fi
  # The README's reset, so it is checked on every run: nothing of the
  # project's may survive it, including the older version's volume.
  { make clean && [[ -z "$(project_volumes)" ]] \
      && [[ -z "$(docker image ls -q datrail-railmon:local)$(docker image ls -q datrail-raildash:local)" ]]; } \
    > "$EVIDENCE_DIR/cleanup.log" 2>&1 || { [[ $result != 0 ]] || result=1; }
  exit "$result"
}
trap cleanup EXIT

uname -a > "$EVIDENCE_DIR/kernel.txt"
test "$(uname -m)" = x86_64
test -r /sys/kernel/btf/vmlinux

# Which commits this run built: the default branch of each component.
for repo in railmon raildash; do
  printf '%s %s\n' "$repo" "$(git ls-remote "https://github.com/datrail/$repo.git" HEAD | cut -f1)"
done | tee "$EVIDENCE_DIR/component-commits.txt"

"${compose[@]}" config --quiet
"${compose[@]}" "${up[@]}" 2>&1 | tee "$EVIDENCE_DIR/up.log"

if [[ $mode == own-agent ]]; then
  [[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]] \
    || { echo "--scale demo-agent=0 still started the demo agent" >&2; exit 1; }
  # The user's agent, started after the stack as INSTALL.md says: here the
  # RailMon image's Python and demo scripts under a process name of its own,
  # serving HTTPS on 8443 the moment it starts and calling itself. Not a
  # Compose service, so RailDash knows it by the scanner's agent key.
  docker run -d --name my-agent --entrypoint /bin/sh -e DEMO_INTERVAL datrail-railmon:local -c '
    set -eu
    demo=/opt/railmon/tools/local-demo
    cp /usr/local/bin/python3 /usr/local/bin/my-agent-bin
    certs=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=127.0.0.1 \
      -keyout "$certs/key.pem" -out "$certs/cert.pem" >/dev/null 2>&1
    my-agent-bin "$demo/demo_server.py" "$certs/cert.pem" "$certs/key.pem" &
    while sleep "$DEMO_INTERVAL"; do my-agent-bin "$demo/demo_client.py" || true; done
  ' > /dev/null
fi

token=""
for _ in $(seq 120); do
  token=$("${compose[@]}" exec -T raildash cat /data/raildash.db.token 2>/dev/null || true)
  [[ -n "$token" ]] && break
  sleep 1
done
[[ -n "$token" ]] || { echo "RailDash never wrote its token file" >&2; exit 1; }

RAILDASH_TOKEN_VALUE="$token" python3 tests/stack_acceptance.py \
  --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" \
  --project "$COMPOSE_PROJECT_NAME" \
  --agent "$([[ $mode == own-agent ]] && echo key:my-agent || echo compose:demo-agent)" \
  --open-port "docker exec -d $agent python3 -m http.server 9000 --bind 127.0.0.1" \
  | tee "$EVIDENCE_DIR/acceptance.txt"
