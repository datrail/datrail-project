#!/usr/bin/env bash
# Walk INSTALL.md as a new user does, on a fresh x86_64 Linux host: the
# throwaway-VM gate of each v0.2.0 release (DR-136, DR-137; DR-252).
#
# Unlike tests/stack-acceptance.sh, which checks the stack in depth from this
# checkout, this runs INSTALL.md's own command lines, at a user's default
# settings, from an empty directory: the clone, the quick start and its
# Verify list, Watch your own agent, Stop and reset, and Without the
# repository. Each command is first checked to appear in INSTALL.md word for
# word, so the walk breaks when the page changes under it.
#
# WALK_REF is the commit the clone and the downloaded file are moved to
# (default: master as cloned). EVIDENCE_DIR receives the transcript, the
# host's facts, the pulled digests, timings and dashboard screenshots.
#
# Run only on a disposable host: it starts the privileged stack under its
# default project names and deletes every image and volume the page's reset
# commands delete.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
install_md="$here/INSTALL.md"
: "${EVIDENCE_DIR:?set an evidence directory outside the checkout}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_DIR=$(cd "$EVIDENCE_DIR" && pwd)
transcript="$EVIDENCE_DIR/transcript.txt"
: > "$transcript"
work=$(mktemp -d)
base=http://127.0.0.1:8000
started=$SECONDS

say() { printf '\n## %s\n' "$*" | tee -a "$transcript"; }
fail() { echo "FAIL: $*" | tee -a "$transcript" >&2; exit 1; }
note() { echo "$*" | tee -a "$transcript"; }

# A command line in one of INSTALL.md's fenced blocks, without a trailing
# `# comment`.
in_block() {
  python3 -I - "$install_md" "$1" <<'PY'
import re, sys
text, want = open(sys.argv[1]).read(), sys.argv[2]
blocks = re.findall(r"^```[a-z]*\n(.*?)^```", text, re.S | re.M)
lines = {re.sub(r"\s+#.*$", "", l).rstrip() for b in blocks for l in b.splitlines()}
sys.exit(0 if want in lines else 1)
PY
}

# Run a command INSTALL.md gives, after checking that it does. `inline` for
# one given in running text rather than a block.
doc() {
  local where=block
  [[ $1 == inline ]] && { where=inline; shift; }
  local cmd=$1
  if [[ $where == block ]]; then
    in_block "$cmd" || fail "INSTALL.md has no command line: $cmd"
  else
    grep -qF "\`$cmd\`" "$install_md" || fail "INSTALL.md does not give: $cmd"
  fi
  printf '$ %s\n' "$cmd" | tee -a "$transcript"
  local t0=$SECONDS status
  set +e
  bash -c "$cmd" 2>&1 | tee -a "$transcript"
  status=${PIPESTATUS[0]}
  set -e
  printf '%5ss  %s\n' "$((SECONDS - t0))" "$cmd" >> "$EVIDENCE_DIR/timings.txt"
  [[ $status == 0 ]] || fail "exit $status: $cmd"
}

# A step the walk takes that INSTALL.md doesn't spell out, said as such.
aside() {
  printf '$ %s    [walk, not INSTALL.md]\n' "$1" | tee -a "$transcript"
  local status
  set +e
  bash -c "$1" 2>&1 | tee -a "$transcript"
  status=${PIPESTATUS[0]}
  set -e
  [[ $status == 0 ]] || fail "exit $status: $1"
}

# Poll a Python check against RailDash until it prints something, or give up.
wait_for() {
  local what=$1 timeout=$2 check=$3 t0=$SECONDS out
  while (( SECONDS - t0 < timeout )); do
    if out=$(python3 -I -c "$check" "$base" 2>/dev/null) && [[ -n $out ]]; then
      note "ok after $((SECONDS - t0))s: $what"
      note "$out"
      printf '%5ss  until: %s\n' "$((SECONDS - t0))" "$what" >> "$EVIDENCE_DIR/timings.txt"
      return 0
    fi
    sleep 5
  done
  fail "not within ${timeout}s: $what"
}

py_api='
import json, re, sys, urllib.request
base = sys.argv[1]
def get(path, token=None):
    req = urllib.request.Request(base + path, headers={"X-RailDash-Token": token} if token else {})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)
def page_token():
    # The token the dashboard page carries for the browser.
    with urllib.request.urlopen(base + "/", timeout=10) as r:
        return re.search(r"<meta name=\"raildash-token\" content=\"([^\"]+)\"", r.read().decode()).group(1)
def answered(asp, name, token):
    attribute = get(f"/api/asps/{asp}/bundle", token)["attributes"][name]
    return attribute.get("value") or [] if attribute.get("status") == "ANSWERED" else []
'

screenshot() {
  local name=$1 browser
  browser=$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)
  if [[ -z $browser ]]; then
    note "no headless browser on this host; no screenshot $name"
    return 0
  fi
  "$browser" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --window-size=1440,2400 --virtual-time-budget=15000 \
    --screenshot="$EVIDENCE_DIR/$name.png" "$base/" > /dev/null 2>&1 \
    || note "screenshot $name failed"
  [[ -s $EVIDENCE_DIR/$name.png ]] && note "screenshot: $name.png"
}

services_up() {
  # Every service Up, and raildash healthy (INSTALL.md, Verify).
  local want=$1 t0=$SECONDS ps
  while (( SECONDS - t0 < 300 )); do
    ps=$(docker compose ps --format '{{.Service}} {{.State}} {{.Health}}')
    if [[ $(grep -c ' running' <<<"$ps") == "$want" ]] && grep -q '^raildash running healthy$' <<<"$ps"; then
      docker compose ps 2>&1 | tee -a "$transcript"
      note "ok after $((SECONDS - t0))s: $want services Up, raildash healthy"
      return 0
    fi
    sleep 5
  done
  docker compose ps -a 2>&1 | tee -a "$transcript"
  fail "not $want services Up with raildash healthy within 300s"
}

project_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=$1"
}
stack_images() {
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^ghcr.io/datrail/(railmon|raildash):' || true
}

save_logs() {
  local status=$?
  if [[ $status != 0 ]]; then
    for dir in "$work/datrail-project" "$work/datrail"; do
      [[ -f $dir/docker-compose.yml ]] || continue
      (cd "$dir" && docker compose ps -a && docker compose logs --no-color) \
        > "$EVIDENCE_DIR/services-$(basename "$dir").log" 2>&1 || true
    done
    docker logs my-agent > "$EVIDENCE_DIR/my-agent.log" 2>&1 || true
  fi
  printf '%5ss  the whole walk\n' "$((SECONDS - started))" >> "$EVIDENCE_DIR/timings.txt"
  exit "$status"
}
trap save_logs EXIT

say "Prerequisites"
{
  echo "date: $(date -u +%FT%TZ)"
  echo "arch: $(uname -m)"
  echo "kernel: $(uname -r)"
  sed -n 's/^PRETTY_NAME=//p' /etc/os-release
  docker version --format 'docker: {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})'
  docker compose version
  git --version
  curl --version | head -1
  make --version | head -1
} 2>&1 | tee "$EVIDENCE_DIR/vm.txt" | tee -a "$transcript"
[[ $(uname -m) == x86_64 ]] || fail "this is the x86_64 walk"
[[ -e /sys/kernel/btf/vmlinux ]] || fail "no /sys/kernel/btf/vmlinux: INSTALL.md needs a BTF-enabled kernel"
note "BTF: /sys/kernel/btf/vmlinux exists"
# A fresh host: nothing of the stack's before the walk.
[[ -z $(stack_images) ]] || fail "the stack's images are already here: $(stack_images)"
[[ -z $(project_volumes datrail-project)$(project_volumes datrail) ]] || fail "the stack's volumes are already here"
[[ -z $(docker ps -aq --filter name=^datrail-demo-agent$ --filter name=^my-agent$) ]] || fail "a container of the walk's is already here"

say "Run it"
cd "$work"
doc "git clone https://github.com/datrail/datrail-project.git"
cd datrail-project
if [[ -n ${WALK_REF:-} ]]; then
  aside "git fetch -q origin $WALK_REF && git checkout -q FETCH_HEAD"
fi
note "at $(git log -1 --format='%h %s')"
doc "docker compose up -d"

say "Verify"
services_up 6
{
  echo "railmon $(docker image inspect --format '{{index .RepoDigests 0}}' "$(docker compose config --format json | jq -r '.services["railmon-collect"].image')")"
  echo "raildash $(docker image inspect --format '{{index .RepoDigests 0}}' "$(docker compose config --format json | jq -r '.services.raildash.image')")"
} | tee "$EVIDENCE_DIR/images.txt" | tee -a "$transcript"
wait_for "the demo agent's POSTs to 127.0.0.1:8443 /v1/demo and /v1/demo/other, status 200" 300 "$py_api"'
rows = [r for r in get("/api/interactions?limit=500")["items"]
        if r.get("method") == "POST" and r.get("status_code") == 200 and r.get("path") in ("/v1/demo", "/v1/demo/other")
        and "127.0.0.1:8443" in (r.get("host") or "") + (r.get("url") or "")]
if {r["path"] for r in rows} == {"/v1/demo", "/v1/demo/other"}:
    r = rows[0]
    print(len(rows), "interactions, e.g.", r["method"], (r.get("host") or "") + r["path"], r["status_code"])
'
wait_for "an ASP for demo-agent: observed_listeners has 8443, observed_file_access has demo_client.py" 300 "$py_api"'
token = page_token()
for asp in get("/api/asps?limit=500")["items"]:
    who = asp.get("agent_identity") or {}
    value = who.get("value")
    if not (who.get("kind") == "deployment_compose" and isinstance(value, dict) and value.get("service") == "demo-agent"):
        continue
    ports = {l.get("port") for l in answered(asp["asp_id"], "observed_listeners", token)}
    files = [f["path"] for f in answered(asp["asp_id"], "observed_file_access", token)]
    if 8443 in ports and any(p.endswith("/demo_client.py") for p in files):
        print("ASP", asp["asp_id"], "listeners", sorted(p for p in ports if isinstance(p, int)), len(files), "files incl. demo_client.py")
        break
'
screenshot dashboard-demo-agent

say "Watch your own agent"
# The user's own agent, in a container of its own image: Python on the
# image's libssl, calling a public HTTPS API and serving on port 9000.
agent_sh='python -m http.server 9000 &
while true; do
  python -c "import urllib.request as u; print(u.urlopen(\"https://api.github.com/zen\").status)" || true
  sleep 30
done'
aside "docker run -d --name my-agent python:3.12-slim sh -c $(printf %q "$agent_sh")"
doc "AGENT_CONTAINER=my-agent docker compose up -d --scale demo-agent=0"
services_up 5
[[ -z $(docker ps -aq --filter name=^datrail-demo-agent$) ]] || fail "--scale demo-agent=0 left the demo agent running"
docker compose logs railmon-collect 2>&1 | grep -iE 'attach' | tail -3 | tee -a "$transcript" || true
wait_for "my-agent's GET https://api.github.com/zen arrives as an interaction" 300 "$py_api"'
rows = [r for r in get("/api/interactions?limit=500")["items"]
        if r.get("path") == "/zen" and "api.github.com" in (r.get("host") or "") + (r.get("url") or "")]
if rows:
    r = rows[0]
    print(len(rows), "interactions, e.g.", r["method"], (r.get("host") or "") + r["path"], r.get("status_code"))
'
wait_for "an ASP for my-agent with port 9000 in observed_listeners" 300 "$py_api"'
token = page_token()
for asp in get("/api/asps?limit=500")["items"]:
    who = asp.get("agent_identity") or {}
    if not ((who.get("kind") == "local_agent_key" and who.get("value") == "my-agent")
            or (who.get("kind") == "local_agent_keys" and "my-agent" in (who.get("value") or []))):
        continue
    ports = {l.get("port") for l in answered(asp["asp_id"], "observed_listeners", token)}
    if 9000 in ports:
        print("ASP", asp["asp_id"], "listeners", sorted(p for p in ports if isinstance(p, int)))
        break
'
screenshot dashboard-my-agent
aside "docker rm -f my-agent"

say "Stop and reset"
token_before=$(docker compose exec -T raildash cat /data/raildash.db.token)
asps_before=$(curl -fsS "$base/api/asps?limit=500" | jq '.items | length')
doc "docker compose down"
[[ -n $(project_volumes datrail-project) ]] || fail "docker compose down deleted the volumes"
aside "docker compose up -d"
services_up 6
[[ $(docker compose exec -T raildash cat /data/raildash.db.token) == "$token_before" ]] \
  || fail "the token changed across down and up"
asps_after=$(curl -fsS "$base/api/asps?limit=500" | jq '.items | length')
(( asps_after >= asps_before )) || fail "ASPs went from $asps_before to $asps_after across down and up"
note "kept across down and up: the token, and $asps_after ASPs ($asps_before before)"
doc "docker compose down -v"
[[ -z $(project_volumes datrail-project) ]] || fail "docker compose down -v left volumes: $(project_volumes datrail-project)"
note "down -v: no volume of the project left"
doc "make clean"
[[ -z $(stack_images) ]] || fail "make clean left images: $(stack_images)"
[[ -z $(docker compose ps -aq) ]] || fail "make clean left containers"
note "make clean: no container, volume or image of the stack left"

say "Without the repository"
cd "$work"
doc "mkdir datrail && cd datrail"
cd datrail
if [[ -n ${WALK_REF:-} ]]; then
  aside "curl -fsSLO https://raw.githubusercontent.com/datrail/datrail-project/$WALK_REF/docker-compose.yml"
  in_block "curl -fsSLO https://raw.githubusercontent.com/datrail/datrail-project/master/docker-compose.yml" \
    || fail "INSTALL.md no longer gives the download command"
else
  doc "curl -fsSLO https://raw.githubusercontent.com/datrail/datrail-project/master/docker-compose.yml"
fi
[[ $(ls -A) == docker-compose.yml ]] || fail "the directory holds more than docker-compose.yml: $(ls -A)"
doc "docker compose up -d"
services_up 6
wait_for "the demo agent's POSTs arrive, from the one downloaded file" 300 "$py_api"'
rows = [r for r in get("/api/interactions?limit=500")["items"]
        if r.get("method") == "POST" and r.get("status_code") == 200 and r.get("path") == "/v1/demo"]
if rows:
    print(len(rows), "interactions")
'
doc inline "docker compose down -v --remove-orphans --rmi all"
[[ -z $(stack_images) ]] || fail "the clean left images: $(stack_images)"
[[ -z $(project_volumes datrail) ]] || fail "the clean left volumes"

say "Done"
note "INSTALL.md walked in $((SECONDS - started))s; nothing of the stack is left on this host."
