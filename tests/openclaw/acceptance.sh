#!/usr/bin/env bash
# A real agent under the install as pinned: OpenClaw, the published npm
# package, watched as INSTALL.md's "Watch your own agent" says, with the
# images docker-compose.yml pins. Its model is a stub on HTTPS in another
# container (tests/openclaw/model_stub.py), so every turn streams a tool
# call the same way and the run needs no model credentials. check.py then
# reads what the stack made of it: the streamed calls with their tool calls
# (railmon#70), and a locked baseline and the adopted guardrail that hold
# while the agent keeps working (railmon#97). OPENCLAW_FORM (exec, the
# default, or gateway) picks how OpenClaw runs: see agent-loop.sh.
#
# Run only on a disposable host, as tests/stack-acceptance.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
for tool in docker curl jq openssl python3; do
  command -v "$tool" > /dev/null || { echo "this needs $tool on PATH" >&2; exit 2; }
done
: "${COMPOSE_PROJECT_NAME:?set a unique compose project name}"
: "${EVIDENCE_DIR:?set an evidence directory outside the checkout}"
mkdir -p "$EVIDENCE_DIR"

export SCAN_INTERVAL="${SCAN_INTERVAL:-10}" TURN_INTERVAL="${TURN_INTERVAL:-10}"
export AGENT_CONTAINER=my-agent OPENCLAW_FORM="${OPENCLAW_FORM:-exec}"
compose=(docker compose)
image=datrail-openclaw-agent:local
network="$COMPOSE_PROJECT_NAME-openclaw"
for name in my-agent my-model; do
  [[ -z "$(docker ps -aq --filter "name=^$name$")" ]] \
    || { echo "a container named $name exists: remove it first (docker rm -f $name)" >&2; exit 1; }
done
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]] \
  || { echo "volumes of compose project $COMPOSE_PROJECT_NAME are left from an earlier run" >&2; exit 1; }
config=$("${compose[@]}" config --format json)
railmon_image=$(jq -r '.services["railmon-collect"].image' <<<"$config")
raildash_image=$(jq -r '.services.raildash.image' <<<"$config")
printf 'railmon %s\nraildash %s\nform %s\n' "$railmon_image" "$raildash_image" "$OPENCLAW_FORM" | tee "$EVIDENCE_DIR/component-images.txt"

certs=$(mktemp -d)
cleanup() {
  local result=$?
  "${compose[@]}" ps -a > "$EVIDENCE_DIR/services.txt" 2>&1 || true
  "${compose[@]}" logs --no-color > "$EVIDENCE_DIR/services.log" 2>&1 || true
  # What railmon-files recorded and what the newest bundle made of it: file
  # paths of the CI agent, nothing secret.
  "${compose[@]}" cp railmon-files:/files/files.jsonl "$EVIDENCE_DIR/files.jsonl" \
    > /dev/null 2>&1 || true
  "${compose[@]}" exec -T railmon-scan python3 -c '
import json
attributes = json.load(open("/.rail/railmon/evidence-bundle.json"))["attributes"]
files = attributes["observed_file_access"]
print(json.dumps({"observed_listeners": attributes["observed_listeners"],
                  "observed_destinations": attributes.get("observed_destinations"),
                  "observed_file_access": {k: v for k, v in files.items() if k != "value"},
                  "files": [f["path"] for f in files.get("value") or []]}, indent=1))
' > "$EVIDENCE_DIR/observed-evidence.json" 2>&1 || true
  docker logs my-agent > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
  docker cp my-agent:/tmp/gateway.log "$EVIDENCE_DIR/gateway.log" > /dev/null 2>&1 || true
  docker logs my-model > "$EVIDENCE_DIR/my-model.log" 2>&1 || true
  docker rm -f my-agent my-model > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
  docker image rm -f "$image" > /dev/null 2>&1 || true
  rm -rf "$certs"
  make clean > "$EVIDENCE_DIR/cleanup.log" 2>&1 || { [[ $result != 0 ]] || result=1; }
  exit "$result"
}
trap cleanup EXIT

docker build -t "$image" tests/openclaw 2>&1 | tee "$EVIDENCE_DIR/build.log"
docker run --rm "$image" openclaw --version | tee "$EVIDENCE_DIR/openclaw-version.txt"

# A throwaway self-signed certificate for the stub, which the agent trusts
# through NODE_EXTRA_CA_CERTS. Both containers run as node, another uid than
# this script's, hence the open modes.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=my-model \
  -addext subjectAltName=DNS:my-model -keyout "$certs/key.pem" -out "$certs/cert.pem" 2>/dev/null
chmod 755 "$certs" && chmod 644 "$certs"/*.pem
docker network create "$network" > /dev/null
docker run -d --name my-model --network "$network" -v "$certs:/certs:ro" "$image" \
  python3 /opt/openclaw-ci/model_stub.py /certs/cert.pem /certs/key.pem > /dev/null

# INSTALL.md's command, then the agent started afterwards.
"${compose[@]}" up -d --scale demo-agent=0 2>&1 | tee "$EVIDENCE_DIR/up.log"
docker run -d --name my-agent --network "$network" -e TURN_INTERVAL -e OPENCLAW_FORM \
  -e NODE_EXTRA_CA_CERTS=/certs/cert.pem -v "$certs/cert.pem:/certs/cert.pem:ro" "$image" > /dev/null

token=""
for _ in $(seq 120); do
  token=$("${compose[@]}" exec -T raildash cat /data/raildash.db.token 2>/dev/null || true)
  [[ -n "$token" ]] && break
  sleep 1
done
[[ -n "$token" ]] || { echo "RailDash never wrote its token file" >&2; exit 1; }

RAILDASH_TOKEN_VALUE="$token" python3 tests/openclaw/check.py \
  --url "http://127.0.0.1:${RAILDASH_PORT:-8000}" --agent my-agent \
  --settle "$((SCAN_INTERVAL * 3))" --watch "$((TURN_INTERVAL * 12))" \
  | tee "$EVIDENCE_DIR/acceptance.txt"
