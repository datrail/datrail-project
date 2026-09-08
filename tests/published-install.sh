#!/usr/bin/env bash
# Run only on an isolated acceptance host: RailMon needs privileged host-PID access.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${COMPOSE_PROJECT_NAME:?set a unique dr99- project name}"
: "${DEMO_SESSION_ID:?set a unique session id}"
: "${DOCKER_CONFIG:?set an empty directory for anonymous registry access}"
: "${EVIDENCE_DIR:?set an evidence directory outside the checkout}"
[[ "$COMPOSE_PROJECT_NAME" =~ ^dr99-[a-z0-9-]+$ ]]
mkdir -p "$DOCKER_CONFIG" "$EVIDENCE_DIR"
[[ -z "$(ls -A "$DOCKER_CONFIG")" ]] || { echo 'DOCKER_CONFIG must be empty'; exit 1; }
export RAILMON_TAG=0.1.0 RAILDASH_TAG=0.1.0
compose=(docker compose)
# Refuse to reuse volumes: a prior import must not make this acceptance pass.
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]]
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]]
cleanup() {
  local result=$?
  "${compose[@]}" ps -a > "$EVIDENCE_DIR/services.txt" 2>&1 || true
  "${compose[@]}" logs --no-color > "$EVIDENCE_DIR/services.log" 2>&1 || true
  "${compose[@]}" down -v > "$EVIDENCE_DIR/cleanup.log" 2>&1 || { [[ $result != 0 ]] || result=1; }
  exit "$result"
}
trap cleanup EXIT
uname -a > "$EVIDENCE_DIR/kernel.txt"
test "$(uname -m)" = x86_64
test -r /sys/kernel/btf/vmlinux
docker info > "$EVIDENCE_DIR/docker-info.txt"
"${compose[@]}" pull 2>&1 | tee "$EVIDENCE_DIR/pull.log"
docker image inspect ghcr.io/datrail/railmon:0.1.0 ghcr.io/datrail/raildash:0.1.0 \
  --format '{{json .RepoDigests}} {{.Os}}/{{.Architecture}}' > "$EVIDENCE_DIR/image-digests.txt"
# This is the public INSTALL.md command, including its first import.
make stack RAILMON_TAG=v0.1.0 RAILDASH_TAG=v0.1.0 2>&1 | tee "$EVIDENCE_DIR/install.log"
"${compose[@]}" exec -T raildash cat /captures/capture.jsonl > "$EVIDENCE_DIR/capture.jsonl"
curl -fsS 'http://127.0.0.1:8000/webhook/health' > "$EVIDENCE_DIR/health.json"
curl -fsS --get --data-urlencode "session_id=$DEMO_SESSION_ID" \
  'http://127.0.0.1:8000/api/overview' > "$EVIDENCE_DIR/overview.json"
curl -fsS --get --data-urlencode "session_id=$DEMO_SESSION_ID" \
  'http://127.0.0.1:8000/api/interactions' > "$EVIDENCE_DIR/interactions.json"
curl -fsS 'http://127.0.0.1:8000/api/sessions' > "$EVIDENCE_DIR/sessions.json"
# The stack's database was populated by webhook. Independently prove a first
# file import inserts into a NEW database, inside this disposable container.
"${compose[@]}" run --rm --entrypoint python3 raildash \
  -m raildash.cli --db /tmp/first-import.db load /captures/capture.jsonl \
  --session-id "$DEMO_SESSION_ID" 2>&1 | tee "$EVIDENCE_DIR/first-file-import.log"
chrome=$(command -v google-chrome || command -v chromium || command -v chromium-browser)
"$chrome" --headless --no-sandbox --disable-gpu --no-proxy-server \
  --user-data-dir="$EVIDENCE_DIR/chrome-profile" --virtual-time-budget=15000 \
  --window-size=1440,1000 --screenshot="$EVIDENCE_DIR/dashboard.png" \
  --dump-dom http://127.0.0.1:8000/ > "$EVIDENCE_DIR/dashboard.html" 2> "$EVIDENCE_DIR/browser.log"
# The profile is browser cache, not useful delivery evidence.
rm -rf "$EVIDENCE_DIR/chrome-profile"
python3 tests/verify-published-install.py "$EVIDENCE_DIR" "$DEMO_SESSION_ID" | tee "$EVIDENCE_DIR/acceptance.txt"
