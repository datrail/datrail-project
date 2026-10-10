#!/usr/bin/env bash
# Bring up docker-compose.yml exactly as the README's quick start does, from
# each component's default branch, and check what a new user should see.
#
# STACK_MODE=own-agent follows INSTALL.md's "Watch your own agent" instead:
# the stack starts without the demo agent, pointed at a container the user
# starts afterwards with `docker run`, which listens on its port at once.
#
# Run only on a disposable host: RailMon's collector, listen probe and files
# probe are privileged and share the host's PID namespace.
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
    export AGENT_CONTAINER=my-agent
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
  # What railmon-files recorded: file paths of the CI agent, nothing secret.
  "${compose[@]}" cp railmon-files:/files/files.jsonl "$EVIDENCE_DIR/files.jsonl" \
    > /dev/null 2>&1 || true
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
  # Compose service, so RailDash knows it by the scanner's agent key. Compose
  # labelled the image it built with its project and service, and a
  # container inherits its image's labels, so they are blanked here: a
  # user's own image has none.
  docker run -d --name my-agent --entrypoint /bin/sh -e DEMO_INTERVAL \
    --label com.docker.compose.project= --label com.docker.compose.service= \
    datrail-railmon:local -c '
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
  --agent-exec "docker exec $agent" \
  --settle "$((SCAN_INTERVAL * 3))" \
  | tee "$EVIDENCE_DIR/acceptance.txt"

# The collector sends RailDash's token with its captures and, while a tap is
# attached, a heartbeat every 60 s: what the Data Guardrail reads to tell a
# quiet agent from a stopped collector (DR-184 M0). Read straight from
# RailDash's database, read-only, since no unauthenticated route shows it.
"${compose[@]}" exec -T raildash python3 - <<'PY' | tee -a "$EVIDENCE_DIR/acceptance.txt"
import datetime, sqlite3, sys, time
deadline = time.time() + 180
while True:
    db = sqlite3.connect("file:/data/raildash.db?mode=ro", uri=True)
    try:
        beat = db.execute("SELECT max(last_heartbeat_at) FROM collector_heartbeats").fetchone()[0]
        authed = db.execute("SELECT count(*) FROM interactions WHERE authenticated = 1").fetchone()[0]
    finally:
        db.close()
    if beat and authed:
        age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(
            beat.replace("Z", "+00:00"))
        if age < datetime.timedelta(minutes=3):
            print(f"ok    the collector's captures are authenticated ({authed}) and it heartbeats ({beat})")
            sys.exit(0)
    if time.time() > deadline:
        sys.exit(f"FAIL  within 180 s: newest heartbeat {beat!r}, authenticated captures {authed}")
    time.sleep(5)
PY

if [[ $mode == own-agent ]]; then
  # INSTALL says the collector follows the agent's container: after a
  # restart, with a new PID nobody looked up, the calls must keep arriving
  # (DR-187).
  # Rows newer than any before the restart (the stopped collector's own
  # flush can still add older calls), timed after it on the wall clock.
  newest_before=$(curl -fsS "http://127.0.0.1:${RAILDASH_PORT:-8000}/api/interactions?limit=1" \
    | python3 -c 'import json,sys; i=json.load(sys.stdin)["items"]; print(i[0]["id"] if i else 0)')
  restarted_at=$(date -u +%Y-%m-%dT%H:%M:%S%z)
  docker restart my-agent > /dev/null
  python3 - "http://127.0.0.1:${RAILDASH_PORT:-8000}" "$newest_before" "$restarted_at" <<'PY' \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
import datetime, json, sys, time, urllib.request
base, newest_before = sys.argv[1], int(sys.argv[2])
restarted = datetime.datetime.strptime(sys.argv[3], "%Y-%m-%dT%H:%M:%S%z")
def at(text):
    t = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)
deadline = time.time() + 180
while time.time() < deadline:
    with urllib.request.urlopen(f"{base}/api/interactions?limit=50", timeout=10) as r:
        rows = json.load(r)["items"]
    after = [x for x in rows if x["id"] > newest_before and x.get("path") == "/v1/demo"
             and x.get("method") == "POST" and x.get("status_code") == 200
             and x.get("timestamp") and at(x["timestamp"]) > restarted]
    if after:
        print(f"ok    the agent's calls arrive again after docker restart my-agent ({len(after)})")
        sys.exit(0)
    time.sleep(2)
sys.exit("FAIL  no interaction from my-agent within 180 s of its restart")
PY
fi
