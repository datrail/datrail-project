#!/usr/bin/env bash
# Bring up docker-compose.yml exactly as the README's quick start does, from
# each component's default branch, and check what a new user should see.
#
# STACK_MODE=own-agent follows INSTALL.md's "Watch your own agent" instead:
# the stack starts without the demo agent, pointed at a container the user
# starts afterwards with `docker run`, which listens on its port at once.
#
# By default both images are built from each component's default branch,
# under local names, so a change there that breaks the stack shows up here.
# RAILMON_IMAGE / RAILDASH_IMAGE run published images instead of a build
# (DR-214), as INSTALL.md's "Images" says: the stack starts without --build,
# so Compose pulls them. STACK_IMAGES=pinned runs the published tags
# docker-compose.yml pins, which is what `docker compose up -d` installs
# (DR-137).
#
# STACK_MODE=openshell runs the same agent in an NVIDIA OpenShell sandbox
# (DR-206), started before the stack, as INSTALL.md's "An agent in an
# OpenShell sandbox" says. It needs OpenShell's gateway with the Docker
# driver running (tests/openshell/install.sh on a CI host).
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
if [[ ${STACK_IMAGES:-} == pinned ]]; then
  [[ -z ${RAILMON_IMAGE:-}${RAILDASH_IMAGE:-} ]] \
    || { echo "STACK_IMAGES=pinned runs docker-compose.yml's own tags; unset RAILMON_IMAGE/RAILDASH_IMAGE" >&2; exit 2; }
  pinned=$("${compose[@]}" config --format json)
  RAILMON_IMAGE=$(jq -r '.services["railmon-collect"].image' <<<"$pinned")
  RAILDASH_IMAGE=$(jq -r '.services.raildash.image' <<<"$pinned")
  [[ $RAILMON_IMAGE == ghcr.io/datrail/railmon:* && $RAILDASH_IMAGE == ghcr.io/datrail/raildash:* ]] \
    || { echo "docker-compose.yml pins no published image: $RAILMON_IMAGE $RAILDASH_IMAGE" >&2; exit 1; }
fi
# The images this run pulls; empty means that component is built.
pull_railmon=${RAILMON_IMAGE:-}
pull_raildash=${RAILDASH_IMAGE:-}
# docker-compose.yml defaults to the pinned published tags, so a build is
# named locally rather than under the published name.
export RAILMON_IMAGE=${RAILMON_IMAGE:-datrail-railmon:local}
export RAILDASH_IMAGE=${RAILDASH_IMAGE:-datrail-raildash:local}
railmon_image=$RAILMON_IMAGE
raildash_image=$RAILDASH_IMAGE
build=(--build)
[[ -z $pull_railmon$pull_raildash ]] || build=()
platform=()
case "$mode" in
  demo)
    agent=datrail-demo-agent
    up=(up -d "${build[@]}")
    ;;
  own-agent)
    # INSTALL.md's command, word for word, plus --build when building.
    agent=my-agent
    export AGENT_CONTAINER=my-agent
    up=(up -d "${build[@]}" --scale demo-agent=0)
    ;;
  openshell)
    # The stack follows the sandbox by name (DR-247): RailMon finds the
    # container, named after an id OpenShell generates, itself, and the agent
    # key defaults to the sandbox name. The container is still looked up
    # below, for the `docker exec`s that drive the agent.
    sandbox=my-agent
    # OpenShell answers the sandbox's DNS itself, on 127.0.0.53 in the
    # agent's own container: listeners the walk sees and allows.
    platform=(--platform-listener tcp/127.0.0.53/53 --platform-listener udp/127.0.0.53/53)
    up=(up -d "${build[@]}" --scale demo-agent=0)
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
  # What railmon-listen recorded, and what the newest bundle made of it:
  # sockets and process names of the CI agent, nothing secret.
  "${compose[@]}" cp railmon-listen:/listen/listen.jsonl "$EVIDENCE_DIR/listen.jsonl" \
    > /dev/null 2>&1 || true
  "${compose[@]}" exec -T railmon-scan python3 -c '
import json
bundle = json.load(open("/.rail/railmon/evidence-bundle.json"))
attributes = bundle["attributes"]
files = attributes["observed_file_access"]
print(json.dumps({"observed_listeners": attributes["observed_listeners"],
                  "observed_file_access": {k: v for k, v in files.items() if k != "value"},
                  "files": [f["path"] for f in files.get("value") or []]}, indent=1))
' > "$EVIDENCE_DIR/observed-evidence.json" 2>&1 || true
  curl -fsS "http://127.0.0.1:${RAILDASH_PORT:-8000}/api/asps?limit=5" \
    > "$EVIDENCE_DIR/asps.json" 2>&1 || true
  # The demo's MCP exchanges as RailDash stored them (DR-205): real captures
  # for RailDash's golden tests. Local, self-signed demo traffic only.
  "${compose[@]}" exec -T raildash python3 -c '
import json, sqlite3
db = sqlite3.connect("file:/data/raildash.db?mode=ro", uri=True)
for row in db.execute("SELECT method, host, path, authenticated, raw FROM interactions WHERE path LIKE ?", ("/mcp%",)):
    print(json.dumps(dict(zip(("method", "host", "path", "authenticated", "raw"), row))))
' > "$EVIDENCE_DIR/mcp-interactions.jsonl" 2>/dev/null || true
  if [[ $mode == own-agent ]]; then
    # The user's own container: not the stack's, so `make clean` leaves it,
    # and it holds the RailMon image the reset removes.
    docker logs my-agent > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
    docker rm -f my-agent > /dev/null 2>&1 || true
  fi
  if [[ $mode == openshell ]]; then
    # The sandbox's image is built on RailMon's, which the reset removes.
    openshell logs "$sandbox" -n 2000 > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
    openshell sandbox delete "$sandbox" > "$EVIDENCE_DIR/sandbox-delete.log" 2>&1 || true
    for _ in $(seq 30); do
      [[ -z "$(sandbox_containers)" ]] && break
      sleep 2
    done
    docker image rm -f datrail-openshell-agent:local > /dev/null 2>&1 || true
  fi
  # The README's reset, so it is checked on every run: nothing of the
  # project's may survive it, including the older version's volume.
  { make clean && [[ -z "$(project_volumes)" ]] \
      && [[ -z "$(docker image ls -q "$railmon_image")$(docker image ls -q "$raildash_image")" ]]; } \
    > "$EVIDENCE_DIR/cleanup.log" 2>&1 || { [[ $result != 0 ]] || result=1; }
  exit "$result"
}
sandbox_containers() {
  docker ps -aq --filter "label=openshell.ai/sandbox-name=${sandbox:-}"
}
trap cleanup EXIT

uname -a > "$EVIDENCE_DIR/kernel.txt"
[[ "$(uname -m)" =~ ^(x86_64|aarch64)$ ]]
test -r /sys/kernel/btf/vmlinux

# Which commits this run built: the default branch of each component.
for repo in railmon raildash; do
  printf '%s %s\n' "$repo" "$(git ls-remote "https://github.com/datrail/$repo.git" HEAD | cut -f1)"
done | tee "$EVIDENCE_DIR/component-commits.txt"

"${compose[@]}" config --quiet
# Each image is built by one service only (DR-212). Compose builds services
# in parallel, and on Docker Desktop every build of an image name after the
# first fails; Docker on GitHub's runners lets them through, so check the file.
"${compose[@]}" config --format json \
  | jq -e '[.services[] | select(.build) | .image] | group_by(.) | all(length == 1)' >/dev/null \
  || { echo "two services build the same image" >&2; exit 1; }
# docker-compose.yml alone is the install (DR-214): no service may read a
# file from this checkout, so downloading the one file is enough.
"${compose[@]}" config --format json \
  | jq -e --arg d "$PWD" '[.. | strings | select(. == $d or startswith($d + "/"))] | length == 0' >/dev/null \
  || { echo "docker-compose.yml reads a file from its repository" >&2; exit 1; }

if [[ $mode == openshell ]]; then
  [[ -z "$(sandbox_containers)" ]]
  # The agent first, then the stack pointed at its container: the order a
  # user with a sandbox already running follows. The demo agent's loop, as
  # the own-agent job runs it, plus one GET to api.github.com per cycle once
  # /sandbox/outbound exists, which only OpenShell's supervisor can carry.
  if [[ -n $pull_railmon ]]; then
    "${compose[@]}" pull railmon-collect 2>&1 | tee "$EVIDENCE_DIR/build.log"
  else
    "${compose[@]}" build railmon-collect 2>&1 | tee "$EVIDENCE_DIR/build.log"
  fi
  docker build -t datrail-openshell-agent:local --build-arg BASE="$railmon_image" tests/openshell \
    2>&1 | tee -a "$EVIDENCE_DIR/build.log"
  openshell sandbox create --name "$sandbox" --from datrail-openshell-agent:local \
    --policy tests/openshell/policy.yaml --detach --no-tty -- sh -c '
    set -eu
    demo=/opt/railmon/tools/local-demo
    certs=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=127.0.0.1 \
      -keyout "$certs/key.pem" -out "$certs/cert.pem" >/dev/null 2>&1
    my-agent-bin "$demo/demo_server.py" "$certs/cert.pem" "$certs/key.pem" &
    while sleep '"$DEMO_INTERVAL"'; do
      my-agent-bin "$demo/demo_client.py" || true
      if [ -e /sandbox/outbound ]; then
        my-agent-bin -c "import urllib.request; urllib.request.urlopen(\"https://api.github.com/zen\", timeout=10).read()" || true
      fi
    done
  ' 2>&1 | tee "$EVIDENCE_DIR/sandbox-create.log"
  # --detach returns as the container is created, so give it a moment to run.
  for _ in $(seq 30); do
    agent=$(docker ps --format '{{.Names}}' --filter "label=openshell.ai/sandbox-name=$sandbox" \
      --filter label=openshell.ai/isolation-role=sandbox)
    [[ -n $agent ]] && break
    sleep 1
  done
  [[ $agent == openshell-* && $agent != *$'\n'* ]] \
    || { echo "no single running sandbox container for $sandbox: '$agent'" >&2; exit 1; }
  docker inspect "$agent" > "$EVIDENCE_DIR/sandbox-container.json"
  echo "sandbox container: $agent" | tee "$EVIDENCE_DIR/sandbox-container.txt"
  export AGENT_CONTAINER=openshell:$sandbox
fi
# With one image named, the other component is still built from its default
# branch, as --build would; `up` then pulls the named one.
if [[ ${#build[@]} == 0 && -z $pull_railmon ]]; then
  "${compose[@]}" build railmon-collect 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
elif [[ ${#build[@]} == 0 && -z $pull_raildash ]]; then
  "${compose[@]}" build raildash 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
fi
"${compose[@]}" "${up[@]}" 2>&1 | tee "$EVIDENCE_DIR/up.log"
# A published image was pulled, not built under its name (Compose builds
# when a pull fails): the local image carries the registry's own digest for
# the tag. On the containerd store a local build has a digest too, just not
# that one. Every service of the component runs it.
for pair in "railmon $pull_railmon" "raildash $pull_raildash"; do
  read -r component image <<<"$pair"
  [[ -n ${image:-} ]] || continue
  remote=$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$image")
  docker image inspect --format '{{join .RepoDigests "\n"}}' "$image" | grep -qxF "${image%:*}@$remote" \
    || { echo "$image was built here, not pulled ($remote)" >&2; exit 1; }
  echo "$component ${image%:*}@$remote" | tee -a "$EVIDENCE_DIR/component-images.txt"
  for id in $("${compose[@]}" ps -q); do
    service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
    [[ $service == "$component"* || ($component == railmon && $service == demo-agent) ]] || continue
    [[ $(docker inspect --format '{{.Config.Image}}' "$id") == "$image" ]] \
      || { echo "$service does not run $image" >&2; exit 1; }
  done
done

if [[ $mode == own-agent ]]; then
  [[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]] \
    || { echo "--scale demo-agent=0 still started the demo agent" >&2; exit 1; }
  # The user's agent, started after the stack as INSTALL.md says: here the
  # RailMon image's Python and demo scripts under a process name of its own,
  # serving HTTPS on 8443 the moment it starts and calling itself. Not a
  # Compose service, so RailDash knows it by the scanner's agent key. Compose
  # labelled the image it built with its project and service, and a
  # container inherits its image's labels, so they are blanked here: a
  # user's own image has none. It declares the demo's MCP server as the
  # demo agent does (DR-237).
  docker run -d --name my-agent --entrypoint /bin/sh -e DEMO_INTERVAL \
    -e AGENT_MCP_NAME=demo -e AGENT_MCP_URL=https://127.0.0.1:8443/mcp \
    --label com.docker.compose.project= --label com.docker.compose.service= \
    "$railmon_image" -c '
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
  --agent "$([[ $mode == demo ]] && echo compose:demo-agent || echo key:my-agent)" \
  --open-port "docker exec -d $agent python3 -m http.server 9000 --bind 127.0.0.1" \
  --open-new-port "docker exec -d $agent python3 -m http.server 9100 --bind 127.0.0.1" \
  --agent-exec "docker exec $agent" \
  --settle "$((SCAN_INTERVAL * 3))" \
  --expect-egress "$([[ $mode == openshell ]] && echo allow_list_enforced || echo open)" \
  ${platform[@]+"${platform[@]}"} \
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

if [[ $mode == openshell ]]; then
  # A call that leaves the sandbox: OpenShell's supervisor terminates the
  # agent's TLS with a CA of its own and makes the real connection, so the
  # agent's own TLS still carries the plaintext the collector reads.
  docker exec "$agent" touch /sandbox/outbound
  python3 - "http://127.0.0.1:${RAILDASH_PORT:-8000}" <<'PY' | tee -a "$EVIDENCE_DIR/acceptance.txt"
import json, sys, time, urllib.request
base = sys.argv[1]
deadline = time.time() + 180
while time.time() < deadline:
    with urllib.request.urlopen(f"{base}/api/interactions?limit=100", timeout=10) as r:
        rows = json.load(r)["items"]
    # Any answer will do: an unauthenticated runner can be rate limited.
    out = [x for x in rows if "api.github.com" in (x.get("host") or "") and x.get("path") == "/zen"
           and x.get("method") == "GET" and x.get("status_code")]
    if out:
        print(f"ok    the agent's GET to api.github.com through OpenShell's supervisor arrives ({len(out)})")
        sys.exit(0)
    time.sleep(3)
sys.exit("FAIL  no GET https://api.github.com/zen from the sandboxed agent within 180 s")
PY
fi
