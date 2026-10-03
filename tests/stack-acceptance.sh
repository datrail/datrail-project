#!/usr/bin/env bash
# Bring up docker-compose.yml exactly as the README's quick start does, from
# each component's default branch, and check what a new user should see.
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

# The stack must start from nothing: leftover volumes would let an earlier
# run's data pass this one.
[[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")" ]]
[[ -z "$(docker ps -aq --filter "name=^datrail-demo-agent$")" ]]

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

# Which commits this run built: the default branch of each component.
for repo in railmon raildash; do
  printf '%s %s\n' "$repo" "$(git ls-remote "https://github.com/datrail/$repo.git" HEAD | cut -f1)"
done | tee "$EVIDENCE_DIR/component-commits.txt"

"${compose[@]}" config --quiet
"${compose[@]}" up -d --build 2>&1 | tee "$EVIDENCE_DIR/up.log"

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
  --open-port "docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1" \
  | tee "$EVIDENCE_DIR/acceptance.txt"
