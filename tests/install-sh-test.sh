#!/usr/bin/env bash
# install.sh's choices, without Docker: a stand-in `docker` on PATH answers
# what install.sh asks and logs what it runs, so each case checks the .env,
# the override file and the commands, in seconds and on any host. The real
# stack is the `existing-agent` job's (tests/stack-acceptance.sh,
# STACK_MODE=existing-agent).
#
# Answers are read from stdin as they are with no terminal (CI, or an agent
# running install.sh), so each run is started in a new session without one.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# The stand-in: FAKE_PS is `docker ps --format`'s output, FAKE_RUNNING the
# running containers' names, FAKE_EXISTING the stopped ones', FAKE_STACKS
# the running RailDash containers' "project|directory".
echo "docker $*" >> "$FAKE_LOG"
last=${!#}
case "$*" in
  "info") exit 0 ;;
  "info --format {{.Architecture}}") echo x86_64 ;;
  "info --format {{.OperatingSystem}}") echo "${FAKE_OS:-Ubuntu 26.04 LTS}" ;;
  "compose version") echo "Docker Compose version v2.40.0" ;;
  run\ --rm\ --privileged\ alpine*) exit 0 ;;
  "compose config") echo "name: $(basename "$PWD")" ;;
  ps\ --format*) printf '%s' "${FAKE_PS:-}" ;;
  ps\ --filter\ label=com.docker.compose.service=raildash*) printf '%s' "${FAKE_STACKS:-}" ;;
  ps\ -q\ --filter\ label=openshell.ai/sandbox-name=*) [[ " ${FAKE_RUNNING:-} " == *" openshell:${4#label=openshell.ai/sandbox-name=} "* ]] && echo abc ;;
  "inspect --type container --format {{.State.Running}} "*)
    if [[ " ${FAKE_RUNNING:-} " == *" $last "* ]]; then echo true
    elif [[ " ${FAKE_EXISTING:-} " == *" $last "* ]]; then echo false
    else exit 1; fi ;;
  "inspect --format {{.State.Health.Status}} raildash-id") echo healthy ;;
  inspect\ *) [[ " ${FAKE_RUNNING:-} ${FAKE_EXISTING:-} " == *" $last "* ]] ;;
  "compose ps -q raildash") echo raildash-id ;;
  "compose ps" | "compose up -d --remove-orphans" | compose\ rm\ -sf\ *) exit 0 ;;
  *) echo "fake docker: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" FAKE_LOG="$work/docker.log"
fails=0

# run DIR ARGS... < answers: install.sh in a session with no terminal
run() {
  local dir=$1; shift
  : > "$FAKE_LOG"
  setsid -w bash "$here/install.sh" --dir "$dir" --compose-file "$here/docker-compose.yml" "$@" \
    > "$work/out" 2>&1
}
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; sed 's/^/      | /' "$work/out"; fails=$((fails + 1)); }
has() { grep -qxF -- "$2" "$1"; }

# 1. --yes --agent: .env and the override; the running agent left alone.
d=$work/one
export FAKE_RUNNING="my-agent" FAKE_PS="" FAKE_EXISTING=""
if run "$d" --yes --agent my-agent < /dev/null \
  && has "$d/.env" AGENT_CONTAINER=my-agent && ! grep -q '^AGENT_KEY=' "$d/.env" \
  && grep -q 'profiles: \[demo\]' "$d/docker-compose.override.yml" \
  && has "$FAKE_LOG" "docker compose rm -sf demo-agent" \
  && has "$FAKE_LOG" "docker compose up -d --remove-orphans" \
  && ! grep -q '^docker restart' "$FAKE_LOG" && grep -q 'No need to restart my-agent' "$work/out" \
  && cmp -s "$d/docker-compose.yml" "$here/docker-compose.yml"; then
  ok "--yes --agent my-agent"
else bad "--yes --agent my-agent"; fi

# 2. Asked: the list leaves out the stack's own containers and an OpenShell
# supervisor, offers a sandbox by name, refuses a bad answer, makes an agent
# key of a name that isn't one.
d=$work/two
export FAKE_RUNNING="My_Agent openshell:box" FAKE_PS="two-raildash-1|ghcr.io/datrail/raildash:x|Up 1 minute|two||
My_Agent|example/agent:1|Up 2 days|||
openshell-box-123|agent:local|Up 1 hour||box|sandbox
openshell-box-sup|supervisor|Up 1 hour||box|supervisor
"
if printf 'x\n9\n1\n' | run "$d" \
  && grep -q '1) My_Agent' "$work/out" && grep -q '2) openshell:box' "$work/out" \
  && ! grep -q 'two-raildash-1\|openshell-box-sup\| 3) ' "$work/out" \
  && grep -q 'Type one of the numbers' "$work/out" \
  && has "$d/.env" AGENT_CONTAINER=My_Agent && has "$d/.env" AGENT_KEY=my_agent; then
  ok "asked: picks from the list, agent key"
else bad "asked: picks from the list, agent key"; fi

# 3. A sandbox: openshell:<name>; the collector only when asked, and its
# profile in .env.
if printf '2\n' | run "$d" && has "$d/.env" AGENT_CONTAINER=openshell:box \
  && ! grep -q '^AGENT_KEY=\|^COMPOSE_PROFILES=' "$d/.env" \
  && has "$FAKE_LOG" "docker compose rm -sf openshell-collector" \
  && grep -q 'No need to restart openshell:box' "$work/out"; then
  ok "asked: an OpenShell sandbox"
else bad "asked: an OpenShell sandbox"; fi
if run "$d" --yes --agent openshell:box --openshell-collector < /dev/null \
  && has "$d/.env" COMPOSE_PROFILES=openshell \
  && ! has "$FAKE_LOG" "docker compose rm -sf openshell-collector"; then
  ok "--openshell-collector"
else bad "--openshell-collector"; fi
if FAKE_OS="Docker Desktop" run "$d" --yes --agent openshell:box < /dev/null; then
  bad "an OpenShell sandbox on Docker Desktop is refused"
else ok "an OpenShell sandbox on Docker Desktop is refused"; fi

# 4. Back to the demo: install.sh's lines and override go, the user's stay.
echo SCAN_INTERVAL=30 >> "$d/.env"
if run "$d" --yes --demo --port 8100 < /dev/null && [[ ! -e $d/docker-compose.override.yml ]] \
  && ! grep -q '^AGENT_CONTAINER=\|^AGENT_KEY=\|^COMPOSE_PROFILES=' "$d/.env" \
  && has "$d/.env" SCAN_INTERVAL=30 && has "$d/.env" RAILDASH_PORT=8100 \
  && grep -q 'http://127.0.0.1:8100' "$work/out"; then
  ok "--demo --port"
else bad "--demo --port"; fi

# 5. What it refuses or stops at.
d=$work/three
if run "$d" --yes < /dev/null; [[ $? == 2 ]]; then ok "--yes alone"; else bad "--yes alone"; fi
if printf 'n\n' | run "$d"; [[ $? == 3 ]] && grep -q 'run it in a container' "$work/out"; then
  ok "not in a container"
else bad "not in a container"; fi
if run "$d" < /dev/null; [[ $? == 2 ]] && grep -q 'no answer' "$work/out"; then
  ok "no answer"
else bad "no answer"; fi
mkdir -p "$work/four" && echo 'services: {}' > "$work/four/docker-compose.override.yml"
if run "$work/four" --yes --agent my-agent < /dev/null; then
  bad "someone else's override file is left alone"
elif grep -q "isn't install.sh's" "$work/out" && has "$work/four/docker-compose.override.yml" 'services: {}'; then
  ok "someone else's override file is left alone"
else bad "someone else's override file is left alone"; fi
export FAKE_RUNNING=""
if run "$d" --yes --agent not-yet < /dev/null && grep -q 'No container named not-yet exists yet' "$work/out" \
  && ! grep -q 'No need to restart' "$work/out"; then
  ok "an agent not started yet"
else bad "an agent not started yet"; fi

# 6. Another copy of the stack running elsewhere; this one's own is fine.
export FAKE_STACKS="datrail-project|/home/u/datrail-project
"
if run "$d" --yes --demo < /dev/null; then bad "another copy of the stack"
elif grep -q 'already running from /home/u/datrail-project' "$work/out"; then ok "another copy of the stack"
else bad "another copy of the stack"; fi
export FAKE_STACKS="three|$d
"
if run "$d" --yes --demo < /dev/null; then ok "this copy of the stack, running"; else bad "this copy of the stack, running"; fi
unset FAKE_STACKS

# 7. An AGENT_KEY in .env for the same agent stays; a new agent gets its own.
d=$work/five
export FAKE_RUNNING="Big_Agent other"
if run "$d" --yes --agent Big_Agent < /dev/null && has "$d/.env" AGENT_KEY=big_agent \
  && sed -i.bak 's/^AGENT_KEY=.*/AGENT_KEY=my-own-key/' "$d/.env" \
  && run "$d" --yes --agent Big_Agent < /dev/null && has "$d/.env" AGENT_KEY=my-own-key \
  && run "$d" --yes --agent other < /dev/null && ! grep -q '^AGENT_KEY=' "$d/.env"; then
  ok "AGENT_KEY kept for the same agent only"
else bad "AGENT_KEY kept for the same agent only"; fi

# 8. Names and numbers that can't be one.
if run "$d" --yes --agent 'a
RAILMON_IMAGE=evil' < /dev/null; [[ $? == 2 ]]; then ok "--agent with a newline"; else bad "--agent with a newline"; fi
if printf 'c\nevil RAILMON_IMAGE=x\n' | run "$d"; [[ $? == 2 ]] && ! grep -q RAILMON_IMAGE "$d/.env"; then
  ok "a typed name with a space"
else bad "a typed name with a space"; fi
if run "$d" --yes --demo --port 70000 < /dev/null; [[ $? == 2 ]]; then ok "--port 70000"; else bad "--port 70000"; fi

# 9. `curl | bash` with no terminal and no --yes: refused at once, not by
# reading the rest of the script as answers.
: > "$FAKE_LOG"
if setsid -w bash -s -- --dir "$d" < "$here/install.sh" > "$work/out" 2>&1; [[ $? == 2 ]] \
  && grep -q "no terminal to ask in" "$work/out" && [[ $(wc -l < "$work/out") -le 2 ]]; then
  ok "piped, no terminal, no --yes"
else bad "piped, no terminal, no --yes"; fi

# ... but with the agent named, nothing is asked, so no --yes is needed.
if setsid -w bash -s -- --dir "$d" --demo < "$here/install.sh" > "$work/out" 2>&1; then
  ok "piped, no terminal, --demo"
else bad "piped, no terminal, --demo"; fi

[[ $fails == 0 ]] || { echo "$fails case(s) failed"; exit 1; }
echo "all cases passed"
