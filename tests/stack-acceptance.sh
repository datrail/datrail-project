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
# STACK_MODE=existing-agent is the case install.sh is for: the user's agent
# is already running, and the stack is brought up by
# `install.sh --agent my-agent --yes`, which writes the .env
# and override file this checkout's docker-compose.yml then runs with.
#
# STACK_MODE=openshell runs the same agent in an NVIDIA OpenShell sandbox
# (DR-206), started before the stack, as INSTALL.md's "An agent in an
# OpenShell sandbox" says. It needs OpenShell's gateway with the Docker
# driver running (tests/openshell/install.sh on a CI host).
#
# Run only on a disposable host: RailMon's collector, listen probe and files
# probe are privileged and share the host's PID namespace. On a Mac that host
# is Docker Desktop's Linux VM (DR-254): the script itself runs under macOS's
# own bash 3.2 and Python 3, so an empty array is expanded only through
# ${a[@]+"${a[@]}"}, which bash 3.2's `set -u` accepts.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in docker git curl jq python3; do
  command -v "$tool" > /dev/null || { echo "make test needs $tool on PATH" >&2; exit 2; }
done
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
    up=(up -d ${build[@]+"${build[@]}"})
    ;;
  own-agent)
    # INSTALL.md's command, word for word, plus --build when building.
    agent=my-agent
    export AGENT_CONTAINER=my-agent
    up=(up -d ${build[@]+"${build[@]}"} --scale demo-agent=0)
    ;;
  existing-agent)
    agent=my-agent
    up=()
    ;;
  openshell)
    # The stack follows the sandbox by name (DR-247): RailMon finds the
    # container, named after an id OpenShell generates, itself, and the agent
    # key defaults to the sandbox name. The container is still looked up
    # below, for the `docker exec`s that drive the agent.
    sandbox=my-agent
    export_sandbox=my-agent-export
    # OpenShell answers the sandbox's DNS itself, on 127.0.0.53 in the
    # agent's own container: listeners the proposal allows (DR-247).
    platform=(--proposal-allows tcp/127.0.0.53/53 --proposal-allows udp/127.0.0.53/53)
    up=(up -d ${build[@]+"${build[@]}"} --scale demo-agent=0)
    # The opt-in collector too (DR-249): it reads the sandbox's policy and
    # denials from OpenShell's gateway with the CLI configuration
    # tests/openshell/install.sh wrote.
    export COMPOSE_PROFILES=openshell OPENSHELL_INTERVAL="$SCAN_INTERVAL"
    ;;
  *) echo "unknown STACK_MODE $mode" >&2; exit 2 ;;
esac

# The kernel the stack runs on is Docker's engine's: the host's own on Linux,
# Docker Desktop's VM on a Mac or Windows (DR-254). So it is asked, not the
# host, with INSTALL's Prerequisites check for BTF. Before the cleanup trap,
# which removes the stack's images, so a host that can't run it loses nothing.
{ uname -a; docker info --format 'engine: {{.OperatingSystem}}, kernel {{.KernelVersion}}, {{.Architecture}}'; } \
  > "$EVIDENCE_DIR/kernel.txt"
arch=$(docker info --format '{{.Architecture}}')
case $arch in
  x86_64 | aarch64) ;;
  *) echo "Docker's engine runs on $arch; the images are built for x86_64 and arm64" >&2; exit 1 ;;
esac
docker run --rm alpine test -r /sys/kernel/btf/vmlinux \
  || { echo "Docker's kernel has no /sys/kernel/btf/vmlinux: RailMon's probes need BTF" >&2; exit 1; }
# A pulled image is checked against the registry's digest with buildx,
# which Docker Desktop ships but a Homebrew or distro docker CLI may not.
[[ -z $pull_railmon$pull_raildash ]] || docker buildx version > /dev/null 2>&1 \
  || { echo "make test needs docker buildx to check the pulled images' digests (install the docker-buildx plugin)" >&2; exit 2; }

# The stack must start from nothing: leftover volumes would let an earlier
# run's data pass this one.
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]] \
  || { echo "volumes of compose project $COMPOSE_PROJECT_NAME are left from an earlier run;" \
         "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME make clean removes them" >&2; exit 1; }
# The containers' names are fixed: the quick start's demo agent has to be
# stopped first (`docker compose down` keeps the stack's data), and so does
# a user's own agent run as INSTALL's my-agent, which isn't the stack's.
[[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]] \
  || { echo "a container named datrail-demo-agent exists: stop your stack first (docker compose down)" >&2; exit 1; }
[[ -z "$(docker ps -aq --filter "name=^my-agent$")" ]] \
  || { echo "a container named my-agent exists: remove it first (docker rm -f my-agent)" >&2; exit 1; }
# install.sh writes these into this checkout, and the cleanup removes them.
[[ $mode != existing-agent || ! ( -e .env || -e docker-compose.override.yml ) ]] \
  || { echo "STACK_MODE=existing-agent writes .env and docker-compose.override.yml here: move yours aside first" >&2; exit 1; }
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
  if [[ $mode == own-agent || $mode == existing-agent ]]; then
    # The user's own container: not the stack's, so `make clean` leaves it,
    # and it holds the RailMon image the reset removes.
    docker logs my-agent > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
    docker rm -f my-agent > /dev/null 2>&1 || true
  fi
  if [[ $mode == openshell ]]; then
    # The sandbox's image is built on RailMon's, which the reset removes.
    openshell logs "$sandbox" -n 2000 > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
    openshell sandbox delete "$sandbox" > "$EVIDENCE_DIR/sandbox-delete.log" 2>&1 || true
    openshell sandbox delete "${export_sandbox:-}" > /dev/null 2>&1 || true
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
  # What install.sh wrote into this checkout (none was there before), kept
  # for the reset above.
  [[ $mode != existing-agent ]] || rm -f .env docker-compose.override.yml
  exit "$result"
}
sandbox_containers() {
  docker ps -aq --filter "label=openshell.ai/sandbox-name=${sandbox:-}"
}
trap cleanup EXIT

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
  # The sandbox, created again by the recreate step (DR-250). Besides the
  # GET, once /sandbox/post exists the agent also POSTs to api.github.com,
  # which its read-only rule lets OpenShell's supervisor refuse at L7.
  create_sandbox() {
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
        if [ -e /sandbox/post ]; then
          my-agent-bin -c "import urllib.request; urllib.request.urlopen(urllib.request.Request(\"https://api.github.com/markdown\", data=b\"{}\", method=\"POST\"), timeout=10).read()" || true
        fi
      done
    ' 2>&1 | tee -a "$EVIDENCE_DIR/sandbox-create.log"
  }
  # --detach returns as the container is created, so give it a moment to run.
  find_agent() {
    for _ in $(seq 30); do
      agent=$(docker ps --format '{{.Names}}' --filter "label=openshell.ai/sandbox-name=$sandbox" \
        --filter label=openshell.ai/isolation-role=sandbox)
      [[ -n $agent ]] && break
      sleep 1
    done
    [[ $agent == openshell-* && $agent != *$'\n'* ]] \
      || { echo "no single running sandbox container for $sandbox: '$agent'" >&2; exit 1; }
  }
  create_sandbox
  find_agent
  docker inspect "$agent" > "$EVIDENCE_DIR/sandbox-container.json"
  echo "sandbox container: $agent" | tee "$EVIDENCE_DIR/sandbox-container.txt"
  export AGENT_CONTAINER=openshell:$sandbox
fi
start_my_agent() {
  # The user's agent: started after the stack as INSTALL.md says, or before
  # it for existing-agent, as install.sh expects. Here the
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
}
if [[ $mode == existing-agent ]]; then
  # The agent needs RailMon's image before the stack starts: pulled when
  # named, else built as `up --build` would.
  if [[ -n $pull_railmon ]]; then
    docker pull "$railmon_image" 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
  else
    "${compose[@]}" build railmon-collect 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
  fi
  [[ -n $pull_raildash ]] || "${compose[@]}" build raildash 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
  start_my_agent
fi
# With one image named, the other component is still built from its default
# branch, as --build would; `up` then pulls the named one.
if [[ $mode == existing-agent ]]; then
  bash install.sh --dir "$PWD" --compose-file docker-compose.yml --agent my-agent --yes \
    2>&1 | tee "$EVIDENCE_DIR/up.log"
  grep -qxF AGENT_CONTAINER=my-agent .env && grep -qF 'profiles: [demo]' docker-compose.override.yml \
    || { echo "install.sh didn't write the settings" >&2; exit 1; }
elif [[ ${#build[@]} == 0 && -z $pull_railmon ]]; then
  "${compose[@]}" build railmon-collect 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
elif [[ ${#build[@]} == 0 && -z $pull_raildash ]]; then
  "${compose[@]}" build raildash 2>&1 | tee -a "$EVIDENCE_DIR/build.log"
fi
[[ $mode == existing-agent ]] || "${compose[@]}" "${up[@]}" 2>&1 | tee "$EVIDENCE_DIR/up.log"
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

if [[ $mode == own-agent || $mode == existing-agent ]]; then
  [[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]] \
    || { echo "the stack still started the demo agent" >&2; exit 1; }
fi
[[ $mode != own-agent ]] || start_my_agent

token=""
for _ in $(seq 120); do
  token=$("${compose[@]}" exec -T raildash cat /data/raildash.db.token 2>/dev/null || true)
  [[ -n "$token" ]] && break
  sleep 1
done
[[ -n "$token" ]] || { echo "RailDash never wrote its token file" >&2; exit 1; }

openshell_policy=()
if [[ $mode == openshell ]]; then
  # DR-250: the file a user imports (INSTALL's OpenShell section). Before
  # importing it, stack_acceptance.py checks the collector's copy arrived
  # (DR-249): the import is newer and becomes what the line shows.
  openshell sandbox get "$sandbox" --policy-only > "$EVIDENCE_DIR/policy.yaml"
  openshell_policy=(--openshell-policy "$EVIDENCE_DIR/policy.yaml")
fi
RAILDASH_TOKEN_VALUE="$token" python3 tests/stack_acceptance.py \
  --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" \
  --project "$COMPOSE_PROJECT_NAME" \
  --agent "$([[ $mode == demo ]] && echo compose:demo-agent || echo key:my-agent)" \
  --open-port "docker exec -d $agent python3 -m http.server 9000 --bind 127.0.0.1" \
  --open-new-port "docker exec -d $agent python3 -m http.server 9100 --bind 127.0.0.1" \
  --agent-exec "docker exec $agent" \
  --settle "$((SCAN_INTERVAL * 3))" \
  --expect-egress "$([[ $mode == openshell ]] && echo allow_list_enforced || echo open)" \
  ${platform[@]+"${platform[@]}"} ${openshell_policy[@]+"${openshell_policy[@]}"} \
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

if [[ $mode == own-agent || $mode == existing-agent ]]; then
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

  # DR-266: railmon scan carries the sandbox's allow-list in the ASP, read
  # from OpenShell by the collector (Daniel, 2026-10-28), not RailDash's record.
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/collector_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --phase allow-list \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  # DR-250: a POST the read-only rule refuses at L7. The supervisor answers
  # the agent's own TLS with a 403, so the capture carries the request, and
  # the collector carries OpenShell's denial of it.
  docker exec "$agent" touch /sandbox/post
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/collector_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --phase l7 \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  docker exec "$agent" rm -f /sandbox/post
  # DR-259 (DR-194 M4): the guardrail in force, downloaded from RailDash as
  # an OpenShell policy (INSTALL's "Enforce the guardrail with OpenShell").
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/export_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --out "$EVIDENCE_DIR/export.yaml" \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  # OpenShell takes it as a policy: a new sandbox created from it alone
  # reaches Ready.
  openshell sandbox create --name "$export_sandbox" --from datrail-openshell-agent:local \
    --policy "$EVIDENCE_DIR/export.yaml" --detach --no-tty -- sleep 3600 2>&1 \
    | tee "$EVIDENCE_DIR/export-sandbox-create.log"
  phase=""
  for _ in $(seq 90); do
    phase=$(openshell sandbox get "$export_sandbox" 2>/dev/null | sed -n 's/^ *Phase: *//p')
    [[ $phase == Ready ]] && break
    sleep 2
  done
  [[ $phase == Ready ]] || { echo "the sandbox created from the export isn't Ready: '$phase'" >&2; exit 1; }
  echo "ok    a sandbox created from the export reaches Ready" | tee -a "$EVIDENCE_DIR/acceptance.txt"
  openshell sandbox delete "$export_sandbox" > "$EVIDENCE_DIR/export-sandbox-delete.log" 2>&1
  # Applied to the agent's own sandbox, then rolled back, as INSTALL says:
  # note the revision loaded now, set the export, then set that revision's
  # policy again. Each `--wait` exits 1 if the sandbox rejects the revision.
  openshell policy list "$sandbox" | tee "$EVIDENCE_DIR/policy-list-before-export.txt"
  loaded=$(awk '$3 == "Loaded" {print $1; exit}' "$EVIDENCE_DIR/policy-list-before-export.txt")
  [[ $loaded =~ ^[0-9]+$ ]] || { echo "no Loaded revision in policy list" >&2; exit 1; }
  openshell policy set "$sandbox" --policy "$EVIDENCE_DIR/export.yaml" --wait 2>&1 \
    | tee "$EVIDENCE_DIR/policy-set-export.log"
  openshell sandbox get "$sandbox" --policy-only > "$EVIDENCE_DIR/policy-after-export.yaml"
  grep -q '^  raildash_api_github_com:' "$EVIDENCE_DIR/policy-after-export.yaml" \
    || { echo "the sandbox's policy isn't the export after policy set" >&2; exit 1; }
  echo "ok    policy set loaded the export into the agent's sandbox" | tee -a "$EVIDENCE_DIR/acceptance.txt"
  openshell policy get "$sandbox" --rev "$loaded" --base --output json | jq -e .policy \
    > "$EVIDENCE_DIR/policy-before-export.json"
  openshell policy set "$sandbox" --policy "$EVIDENCE_DIR/policy-before-export.json" --wait 2>&1 \
    | tee "$EVIDENCE_DIR/policy-set-rollback.log"
  openshell sandbox get "$sandbox" --policy-only > "$EVIDENCE_DIR/policy-after-rollback.yaml"
  grep -q '^  github_api:' "$EVIDENCE_DIR/policy-after-rollback.yaml" \
    && ! grep -q 'raildash_' "$EVIDENCE_DIR/policy-after-rollback.yaml" \
    || { echo "the rollback didn't restore revision $loaded's policy" >&2; exit 1; }
  echo "ok    rolled back to revision $loaded through policy get --base --output json" \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  # DR-249: removing the rule that lets the agent reach api.github.com makes
  # OpenShell's supervisor refuse its next call at L4; the collector posts
  # that denial and the new revision, and RailDash shows both. Read through
  # RailDash's token-gated guardrail detail, as the panel reads them.
  openshell policy update "$sandbox" --remove-rule github_api --wait 2>&1 \
    | tee "$EVIDENCE_DIR/policy-update.log"
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/collector_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --phase denial \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/collector_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --phase allow-list-removed \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
  # DR-250: a new sandbox under the same name is followed without restarting
  # anything (DR-247's promise, INSTALL): its container has a new name, and
  # its calls still arrive under the same agent.
  before=$agent
  # The first sandbox's log, with its denials, before it goes.
  openshell logs "$sandbox" -n 2000 > "$EVIDENCE_DIR/my-agent-first-sandbox.log" 2>&1 || true
  openshell sandbox delete "$sandbox" 2>&1 | tee "$EVIDENCE_DIR/sandbox-recreate-delete.log"
  for _ in $(seq 60); do [[ -z "$(sandbox_containers)" ]] && break; sleep 2; done
  [[ -z "$(sandbox_containers)" ]] || { echo "the deleted sandbox's containers are still there" >&2; exit 1; }
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  create_sandbox
  find_agent
  [[ $agent != "$before" ]] || { echo "the recreated sandbox kept its container name $agent" >&2; exit 1; }
  echo "recreated sandbox container: $agent (was $before)" | tee -a "$EVIDENCE_DIR/sandbox-container.txt"
  RAILDASH_TOKEN_VALUE="$token" python3 tests/openshell/collector_acceptance.py \
    --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --phase recreated --since "$since" \
    | tee -a "$EVIDENCE_DIR/acceptance.txt"
fi
