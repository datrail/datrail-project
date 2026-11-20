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
# The stand-in: FAKE_INFO_ERR makes `docker info` fail with that error,
# FAKE_PS is `docker ps --format`'s output, FAKE_RUNNING the
# running containers' names, FAKE_EXISTING the stopped ones', FAKE_STACKS
# the running RailDash containers' "project|directory". RailMon's image is
# ghcr.io/datrail/railmon:test, or the RAILMON_IMAGE in .env in the current
# directory; FAKE_NOT_PULLED says it isn't on the host yet, FAKE_PULL_FAILS
# that pulling it fails, FAKE_NO_BTF that the kernel check fails in it.
# For an upgrade: FAKE_NEW_IMAGES and FAKE_OLD_IMAGES are the images
# docker-compose.yml and docker-compose.yml.old name, FAKE_IN_USE the images
# a container uses, FAKE_ALPINE that alpine:latest is on the host, and
# FAKE_RM_FAILS that removing an image fails.
echo "docker $*" >> "$FAKE_LOG"
last=${!#}
case "$*" in
  "info") [ -z "${FAKE_INFO_ERR:-}" ] || { printf '%s
' "$FAKE_INFO_ERR" >&2; exit 1; } ;;
  "info --format {{.Architecture}}") echo x86_64 ;;
  "info --format {{.OperatingSystem}}") echo "${FAKE_OS:-Ubuntu 26.04 LTS}" ;;
  "compose version") echo "Docker Compose version v2.40.0" ;;
  "compose config --images docker-proxy") echo nginx:1.30-alpine ;;
  "compose config --images railmon-listen")
    image=$(sed -n 's/^RAILMON_IMAGE=//p' .env 2> /dev/null | tail -n 1)
    printf 'nginx:1.30-alpine\n%s\n' "${image:-ghcr.io/datrail/railmon:test}" ;;
  "image inspect "*) [ -z "${FAKE_NOT_PULLED:-}" ] ;;
  "pull -q "*) [ -z "${FAKE_PULL_FAILS:-}" ] && echo sha256:0123 ;;
  "run --rm --cap-add BPF --cap-add PERFMON --cap-add SYS_ADMIN --entrypoint test "*" -r /sys/kernel/btf/vmlinux")
    [ -z "${FAKE_NO_BTF:-}" ] ;;
  "compose config") echo "name: $(basename "$PWD")" ;;
  "compose config --images") printf '%s\n' ${FAKE_NEW_IMAGES:-ghcr.io/datrail/railmon:test nginx:1.30-alpine} ;;
  "compose -f "*"/docker-compose.yml.old config --images") printf '%s\n' ${FAKE_OLD_IMAGES:-} ;;
  "image inspect alpine:latest") [ -n "${FAKE_ALPINE:-}" ] ;;
  "ps -aq --filter ancestor="*) [[ " ${FAKE_IN_USE:-} " == *" ${last#ancestor=} "* ]] && echo abc ;;
  "image rm "*) [ -z "${FAKE_RM_FAILS:-}" ] ;;
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
# `uname -s` is FAKE_UNAME (Linux unless set), so the cases read the same on a
# Mac; anything else is the real uname.
cat > "$work/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = -s ]; then echo "${FAKE_UNAME:-Linux}"; else PATH=/usr/bin:/bin exec uname "$@"; fi
EOF
# `curl -fsSL URL -o FILE`, for the download path: FILE becomes FAKE_COMPOSE,
# this checkout's docker-compose.yml unless a case names another.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
cp "$FAKE_COMPOSE" "${!#}"
EOF
chmod +x "$work/bin/docker" "$work/bin/uname" "$work/bin/curl"
export PATH="$work/bin:$PATH" FAKE_LOG="$work/docker.log" FAKE_COMPOSE="$here/docker-compose.yml"
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

# 10. Docker unreachable: each cause gets its own message, in either of
# Docker's wordings, with the socket checked rather than the words.
d=$work/six
sock_dir=$(mktemp -d "$work/sock.XXXXXX")
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock_dir/dead.sock"
unreachable() { # unreachable NAME ERROR EXPECTED...
  local name=$1 err=$2; shift 2
  if FAKE_INFO_ERR=$err run "$d" --yes --demo < /dev/null; then bad "$name"; return; fi
  for want in "$@"; do grep -qF -- "$want" "$work/out" || { bad "$name"; return; }; done
  ! has "$FAKE_LOG" "docker compose up -d --remove-orphans" || { bad "$name"; return; }
  # Desktop's message only where the case expects it.
  [[ " $* " == *"Docker Desktop isn't running"* ]] || ! grep -qF "Docker Desktop isn't running" "$work/out" \
    || { bad "$name"; return; }
  ok "$name"
}
unreachable "docker: no daemon socket yet" \
  "failed to connect to the docker API at unix://$sock_dir/none.sock; check if the path is correct and if the daemon is running: dial unix $sock_dir/none.sock: connect: no such file or directory" \
  "no daemon socket at $sock_dir/none.sock" "still being installed" "sudo systemctl start docker"
unreachable "docker: a socket but no daemon" \
  "Cannot connect to the Docker daemon at unix://$sock_dir/dead.sock. Is the docker daemon running?" \
  "Docker's socket ($sock_dir/dead.sock) is there, but the daemon doesn't answer" "sudo systemctl start docker"
unreachable "docker: permission denied" \
  "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock" \
  "permission denied on /var/run/docker.sock)" "sudo usermod -aG docker" "equivalent to root"
unreachable "docker: permission denied, older wording" \
  "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.24/info\": dial unix /var/run/docker.sock: connect: permission denied" \
  "permission denied on /var/run/docker.sock)"
unreachable "docker: anything else, in Docker's words" \
  "error during connect: this error is new" \
  "Docker says: error during connect: this error is new"
unreachable "docker: an SSH key refused, for a remote DOCKER_HOST" \
  "error during connect: Get \"http://docker.example/v1.47/info\": command [ssh -- ana@docker.example docker system dial-stdio] has exited with exit status 255, make sure the URL is valid, and Docker 18.09 or later is installed on the remote host: stderr=ana@docker.example: Permission denied (publickey)." \
  "Docker says: error during connect"
unreachable "docker: Docker Desktop's socket" \
  "Cannot connect to the Docker daemon at unix:///home/ana/.docker/desktop/docker.sock. Is the docker daemon running?" \
  "Docker Desktop isn't running"
FAKE_UNAME=Darwin unreachable "docker: a Mac without Docker Desktop" \
  "Cannot connect to the Docker daemon at unix://$sock_dir/colima.sock. Is the docker daemon running?" \
  "no daemon socket at $sock_dir/colima.sock" "colima start"

# Docker Desktop's CLI (in WSL, /usr/bin/docker links into
# /mnt/wsl/docker-desktop/cli-tools): Desktop's advice only when the error
# names no socket or /var/run/docker.sock and the user may open it.
mkdir -p "$work/docker-desktop/cli-tools/usr/bin" "$work/desktop-bin"
cp "$work/bin/docker" "$work/docker-desktop/cli-tools/usr/bin/docker"
ln -s "$work/docker-desktop/cli-tools/usr/bin/docker" "$work/desktop-bin/docker"
PATH="$work/desktop-bin:$PATH" unreachable "docker: permission denied through Desktop's CLI in WSL" \
  "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock" \
  "permission denied on /var/run/docker.sock)" "sudo usermod -aG docker"
PATH="$work/desktop-bin:$PATH" unreachable "docker: Desktop's CLI, Desktop not answering" \
  "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" \
  "Docker Desktop isn't running"
PATH="$work/desktop-bin:$PATH" FAKE_UNAME=Darwin unreachable "docker: Desktop's CLI with Colima's socket on a Mac" \
  "Cannot connect to the Docker daemon at unix://$sock_dir/colima.sock. Is the docker daemon running?" \
  "no daemon socket at $sock_dir/colima.sock" "colima start"

# 11. The kernel check runs in RailMon's own image, pulled only when it isn't
# on the host yet, and in no other image (DR-311). --check leaves the
# install directory alone.
d=$work/seven
export FAKE_RUNNING="" FAKE_PS=""
probe_check="docker run --rm --cap-add BPF --cap-add PERFMON --cap-add SYS_ADMIN --entrypoint test ghcr.io/datrail/railmon:test -r /sys/kernel/btf/vmlinux"
if run "$d" --yes --demo < /dev/null && has "$FAKE_LOG" "$probe_check" \
  && ! grep -q '^docker pull' "$FAKE_LOG" && ! grep -q alpine "$FAKE_LOG" \
  && grep -q "RailMon's probes can run here: OK" "$work/out"; then
  ok "the kernel check runs in RailMon's image"
else bad "the kernel check runs in RailMon's image"; fi
if FAKE_NOT_PULLED=1 run "$d" --yes --demo < /dev/null \
  && has "$FAKE_LOG" "docker pull -q ghcr.io/datrail/railmon:test" && grep -q "Pulling RailMon's image" "$work/out"; then
  ok "RailMon's image pulled for the check when it isn't there"
else bad "RailMon's image pulled for the check when it isn't there"; fi
if FAKE_NOT_PULLED=1 FAKE_PULL_FAILS=1 run "$d" --yes --demo < /dev/null; then bad "a pull that fails"
elif grep -q "couldn't pull ghcr.io/datrail/railmon:test" "$work/out" \
  && ! has "$FAKE_LOG" "docker compose up -d --remove-orphans"; then ok "a pull that fails"
else bad "a pull that fails"; fi
if FAKE_NO_BTF=1 run "$d" --yes --demo < /dev/null; then bad "no BTF, or the capabilities refused"
elif grep -q "Docker can't run RailMon's probes here" "$work/out" \
  && ! has "$FAKE_LOG" "docker compose up -d --remove-orphans"; then ok "no BTF, or the capabilities refused"
else bad "no BTF, or the capabilities refused"; fi
d=$work/eight
if run "$d" --check < /dev/null && grep -q "This machine can run DatRail." "$work/out" \
  && has "$FAKE_LOG" "$probe_check" && [[ ! -e $d ]]; then
  ok "--check, without touching the install directory"
else bad "--check, without touching the install directory"; fi
if FAKE_NO_BTF=1 run "$d" --check < /dev/null; then bad "--check, no BTF"
elif grep -q "Docker can't run RailMon's probes here" "$work/out" && [[ ! -e $d ]]; then ok "--check, no BTF"
else bad "--check, no BTF"; fi
# An install's own RAILMON_IMAGE is the image --check checks, and .env is
# left as it was.
mkdir -p "$d" && printf 'RAILMON_IMAGE=example.com/railmon:mine\n' > "$d/.env"
if run "$d" --check < /dev/null \
  && has "$FAKE_LOG" "docker run --rm --cap-add BPF --cap-add PERFMON --cap-add SYS_ADMIN --entrypoint test example.com/railmon:mine -r /sys/kernel/btf/vmlinux" \
  && [[ $(cat "$d/.env") == RAILMON_IMAGE=example.com/railmon:mine && ! -e $d/docker-compose.yml ]]; then
  ok "--check, with the install's own RAILMON_IMAGE"
else bad "--check, with the install's own RAILMON_IMAGE"; fi

# 12. An upgrade (DR-313): install.sh downloads docker-compose.yml over an
# older one. DatRail's images only the old file named go once RailDash is
# healthy; another image, or one a container still uses, stays, and the line
# to remove the other is printed. --compose-file and an unchanged download
# remove nothing.
upgrade() { # upgrade DIR: install.sh over an older docker-compose.yml, downloaded
  mkdir -p "$1" && echo "# the older release" > "$1/docker-compose.yml"
  : > "$FAKE_LOG"
  setsid -w bash "$here/install.sh" --dir "$1" --yes --demo \
    > "$work/out" 2>&1
}
old="ghcr.io/datrail/railmon:old ghcr.io/datrail/raildash:old nginx:1.29-alpine nginx:1.30-alpine"
d=$work/nine
if FAKE_OLD_IMAGES=$old upgrade "$d" < /dev/null \
  && has "$FAKE_LOG" "docker image rm ghcr.io/datrail/railmon:old" \
  && has "$FAKE_LOG" "docker image rm ghcr.io/datrail/raildash:old" \
  && ! grep -q '^docker image rm nginx' "$FAKE_LOG" \
  && grep -qF 'to free the space: docker image rm nginx:1.29-alpine' "$work/out" \
  && [[ -f $d/docker-compose.yml.old ]] \
  && [[ $(grep -n '^docker image rm' "$FAKE_LOG" | head -n 1 | cut -d: -f1) -gt $(grep -n '^docker inspect --format {{.State.Health.Status}}' "$FAKE_LOG" | tail -n 1 | cut -d: -f1) ]]; then
  ok "an upgrade removes the old release's DatRail images, after RailDash is healthy"
else bad "an upgrade removes the old release's DatRail images, after RailDash is healthy"; fi
d=$work/ten
if FAKE_OLD_IMAGES=$old FAKE_IN_USE=ghcr.io/datrail/raildash:old FAKE_ALPINE=1 upgrade "$d" < /dev/null \
  && has "$FAKE_LOG" "docker image rm ghcr.io/datrail/railmon:old" \
  && ! has "$FAKE_LOG" "docker image rm ghcr.io/datrail/raildash:old" \
  && grep -qF 'Keeping ghcr.io/datrail/raildash:old: a container still uses it.' "$work/out" \
  && ! has "$FAKE_LOG" "docker image rm alpine:latest" \
  && grep -qF 'docker image rm nginx:1.29-alpine alpine:latest' "$work/out"; then
  ok "an upgrade keeps an image in use, and prints alpine:latest's removal"
else bad "an upgrade keeps an image in use, and prints alpine:latest's removal"; fi
d=$work/eleven
if FAKE_OLD_IMAGES=$old FAKE_RM_FAILS=1 upgrade "$d" < /dev/null \
  && grep -qF 'docker image rm ghcr.io/datrail/raildash:old ghcr.io/datrail/railmon:old nginx:1.29-alpine' "$work/out" \
  && ! grep -q 'Removed the previous release' "$work/out"; then
  ok "an image that won't go is printed with the others"
else bad "an image that won't go is printed with the others"; fi
d=$work/twelve
mkdir -p "$d" && cp "$here/docker-compose.yml" "$d/docker-compose.yml"
: > "$FAKE_LOG"
if FAKE_OLD_IMAGES=$old setsid -w bash "$here/install.sh" --dir "$d" --yes --demo \
    > "$work/out" 2>&1 < /dev/null \
  && ! grep -q '^docker image rm\|docker-compose.yml.old' "$FAKE_LOG" && [[ ! -e $d/docker-compose.yml.old ]] \
  && FAKE_OLD_IMAGES=$old run "$d" --yes --demo < /dev/null && ! grep -q '^docker image rm' "$FAKE_LOG"; then
  ok "an unchanged download, or --compose-file, removes nothing"
else bad "an unchanged download, or --compose-file, removes nothing"; fi

[[ $fails == 0 ]] || { echo "$fails case(s) failed"; exit 1; }
echo "all cases passed"
