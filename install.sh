#!/usr/bin/env bash
# Install DatRail (RailMon + RailDash) and point it at an agent you already
# run, asking as it goes. One command, from nothing:
#
#   curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash
#
# or, with no questions, for a script or for an AI agent doing the install:
#
#   curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh \
#     | bash -s -- --agent my-agent --yes
#
# It checks that Docker can run the stack, downloads docker-compose.yml into
# a directory of its own (~/datrail by default), writes the choices into a
# .env file beside it, starts the stack, and waits until RailDash answers.
# Afterwards, plain `docker compose` commands in that directory work as
# INSTALL.md describes. Running it again changes the choices in place; it
# never deletes RailDash's data.
#
# It runs under macOS's own bash 3.2 as well as Linux's bash, and needs only
# docker and curl.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Which agent to watch (asked if none is given):
  --agent NAME            the Docker container NAME, or openshell:SANDBOX for
                          an agent in an NVIDIA OpenShell sandbox
  --demo                  the demo agent the stack brings along

Options:
  --dir DIR               where the stack's files go (default: ~/datrail)
  --openshell-collector   also run the OpenShell collector (INSTALL.md says
                          what it holds); only with --agent openshell:SANDBOX
  --port PORT             RailDash's local port (default 8000)
  --ref REF               the git branch, tag or commit of datrail-project to
                          download docker-compose.yml from (default master)
  --compose-file FILE     use this docker-compose.yml instead of downloading
  --check                 only check that this machine can run the stack
  -y, --yes               ask nothing; needs --agent or --demo
  -h, --help              this text
EOF
}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit "${2:-1}"; }

agent=""
demo=0
dir="${DATRAIL_DIR:-$HOME/datrail}"
openshell_collector=0
port=""
ref=master
compose_file=""
check_only=0
yes=0
while [ $# -gt 0 ]; do
  case $1 in
    --agent) [ $# -ge 2 ] || die "--agent needs a name" 2; agent=$2; shift ;;
    --agent=*) agent=${1#*=} ;;
    --demo) demo=1 ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a directory" 2; dir=$2; shift ;;
    --dir=*) dir=${1#*=} ;;
    --openshell-collector) openshell_collector=1 ;;
    --port) [ $# -ge 2 ] || die "--port needs a number" 2; port=$2; shift ;;
    --port=*) port=${1#*=} ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a branch, tag or commit" 2; ref=$2; shift ;;
    --ref=*) ref=${1#*=} ;;
    --compose-file) [ $# -ge 2 ] || die "--compose-file needs a file" 2; compose_file=$2; shift ;;
    --compose-file=*) compose_file=${1#*=} ;;
    --check) check_only=1 ;;
    -y | --yes) yes=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
  shift
done
[ -n "$agent" ] && [ "$demo" = 1 ] && die "--agent and --demo exclude each other" 2
if [ -n "$port" ]; then
  case $port in '' | *[!0-9]*) die "--port takes a number: $port" 2 ;; esac
fi
case $ref in '' | *[!A-Za-z0-9._/-]*) die "--ref takes a branch, tag or commit: $ref" 2 ;; esac

# Answers come from the terminal, so `curl ... | bash` can still ask: there
# stdin is the script itself. Without a terminal (CI, or an agent running
# this), they come from stdin.
if [ "$yes" = 0 ] && { exec 3< /dev/tty; } 2> /dev/null; then
  :
else
  exec 3<&0
fi
ask() { # ask PROMPT DEFAULT -> $answer
  if [ "$yes" = 1 ]; then answer=$2; return; fi
  printf '%s ' "$1" >&2
  if ! IFS= read -r answer <&3; then
    die "no answer to \"$1\" (no terminal); run with --yes and --agent or --demo" 2
  fi
  [ -n "$answer" ] || answer=$2
}

# ---------------------------------------------------------------- the machine
step "Checking that this machine can run DatRail"
command -v docker > /dev/null 2>&1 || die "Docker isn't installed. Install Docker (Docker Desktop on a Mac or Windows, Docker Engine on Linux), then run this again. INSTALL.md#prerequisites says more."
command -v curl > /dev/null 2>&1 || [ -n "$compose_file" ] || die "curl isn't installed; install it, then run this again."
docker info > /dev/null 2>&1 || die "Docker is installed but not running, or this user can't reach it. Start Docker (Docker Desktop: open it and wait until it says it's running), or on Linux add yourself to the docker group, then run this again."
docker compose version > /dev/null 2>&1 || die "Docker Compose v2 (\`docker compose\`) is missing. Docker Desktop includes it; on Linux install the docker-compose-plugin package."
engine_arch=$(docker info --format '{{.Architecture}}')
engine_os=$(docker info --format '{{.OperatingSystem}}')
case $engine_arch in
  x86_64 | aarch64) ;;
  *) die "Docker's engine runs on $engine_arch; DatRail's images are built for x86_64 and arm64." ;;
esac
# The probes are privileged and read BTF from the kernel Docker runs on: the
# host's own on Linux, Docker Desktop's VM on a Mac or Windows.
docker run --rm --privileged alpine test -r /sys/kernel/btf/vmlinux > /dev/null 2>&1 \
  || die "Docker can't run a privileged container with BTF (/sys/kernel/btf/vmlinux) here. RailMon's probes need both; INSTALL.md#prerequisites says which setups have them."
desktop=0
case "$(uname -s) $engine_os" in
  Darwin* | *"Docker Desktop"*) desktop=1 ;;
esac
say "Docker $engine_arch, $engine_os: OK"
if [ "$desktop" = 1 ]; then
  say "Note: with Docker Desktop, DatRail sees only agents running in Docker containers, not one running directly on this computer."
fi
[ "$check_only" = 1 ] && { say "This machine can run DatRail."; exit 0; }

# ----------------------------------------------------------- the stack's files
step "Getting docker-compose.yml into $dir"
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
target="$dir/docker-compose.yml"
if [ -n "$compose_file" ]; then
  [ -r "$compose_file" ] || die "can't read $compose_file"
  src=$(cd "$(dirname "$compose_file")" && pwd)/$(basename "$compose_file")
  [ "$src" = "$target" ] || cp "$src" "$target"
else
  url="https://raw.githubusercontent.com/datrail/datrail-project/$ref/docker-compose.yml"
  curl -fsSL "$url" -o "$target.new" || die "couldn't download $url"
  if [ -f "$target" ] && ! cmp -s "$target" "$target.new"; then
    say "Updating the docker-compose.yml already there (the old one is kept as docker-compose.yml.old)."
    mv "$target" "$target.old"
  fi
  mv "$target.new" "$target"
fi
cd "$dir"
# Compose names the project after the directory; the containers it labels
# with that name are the stack's own, not an agent to watch.
project=$(docker compose config 2> /dev/null | sed -n 's/^name: //p')
[ -n "$project" ] || die "docker compose can't read $target"

# ------------------------------------------------------------- which agent
# Running containers that could be the agent: one line each,
# "choice|image|status" ('|', since a tab is whitespace to `read` and an
# empty label between two would vanish). An OpenShell sandbox is offered by its name, as
# openshell:<sandbox>; its other containers and this stack's are left out.
candidates() {
  docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Label "com.docker.compose.project"}}|{{.Label "openshell.ai/sandbox-name"}}|{{.Label "openshell.ai/isolation-role"}}' \
    | while IFS='|' read -r name image status cproject sandbox role; do
        [ "$cproject" = "$project" ] && continue
        [ "$name" = datrail-demo-agent ] && continue
        if [ -n "$sandbox" ]; then
          [ "$role" = sandbox ] || continue
          name="openshell:$sandbox"
        fi
        printf '%s|%s|%s\n' "$name" "$image" "$status"
      done
}

running() { # running CHOICE: the container (or sandbox's container) is up
  case $1 in
    openshell:*)
      [ -n "$(docker ps -q --filter "label=openshell.ai/sandbox-name=${1#openshell:}" --filter label=openshell.ai/isolation-role=sandbox)" ] ;;
    *) [ "$(docker inspect --format '{{.State.Running}}' "$1" 2> /dev/null)" = true ] ;;
  esac
}

not_in_a_container() {
  say ""
  say "DatRail watches an agent that runs in a Docker container (or an OpenShell sandbox)."
  if [ "$desktop" = 1 ]; then
    say "With Docker Desktop it can't see an agent running directly on this computer at all."
  else
    say "On Linux it can capture the TLS calls of an agent outside a container (COLLECT_TARGET in INSTALL.md),"
    say "but not the files and ports it opens, so its profile stays incomplete."
  fi
  say "To watch your agent fully, run it in a container, then run this again and pick it."
  say "INSTALL.md#watch-your-own-agent says more; or run this with --demo to try DatRail first."
}

if [ "$demo" = 0 ] && [ -z "$agent" ]; then
  [ "$yes" = 0 ] || die "--yes needs --agent NAME or --demo" 2
  step "Which agent should DatRail watch?"
  list=$(candidates)
  i=0
  if [ -n "$list" ]; then
    say "Containers running now:"
    while IFS='|' read -r name image status; do
      i=$((i + 1))
      printf '  %2d) %s   (%s, %s)\n' "$i" "$name" "$image" "$status"
    done <<EOF
$list
EOF
  else
    say "No container is running now, apart from DatRail's own."
  fi
  say "   d) the demo agent, to try DatRail first"
  say "   o) an agent in an OpenShell sandbox that isn't running yet (you'll type its name)"
  say "   c) a container that isn't running yet (you'll type its name)"
  say "   n) my agent doesn't run in a container"
  while :; do
    ask "Your choice:" ""
    case $answer in
      d | D) demo=1; break ;;
      o | O) ask "The sandbox's name:" ""; [ -n "$answer" ] && { agent="openshell:$answer"; break; } ;;
      c | C) ask "The container's name:" ""; [ -n "$answer" ] && { agent=$answer; break; } ;;
      n | N) not_in_a_container; exit 3 ;;
      *[!0-9]* | '') ;;
      *)
        if [ "$answer" -ge 1 ] && [ "$answer" -le "$i" ]; then
          agent=$(printf '%s\n' "$list" | sed -n "${answer}p" | cut -d'|' -f1)
          break
        fi
        ;;
    esac
    say "Type one of the numbers or letters above."
  done
fi

if [ -n "$agent" ]; then
  case $agent in
    openshell:) die "openshell: needs the sandbox's name: openshell:<sandbox>" 2 ;;
    datrail-demo-agent) demo=1; agent="" ;;
  esac
fi
if [ -n "$agent" ]; then
  case $agent in
    openshell:*)
      [ "$desktop" = 0 ] || die "an agent in an OpenShell sandbox needs native Linux; OpenShell doesn't run on Docker Desktop (INSTALL.md#an-agent-in-an-openshell-sandbox)."
      ;;
    *)
      docker inspect "$agent" > /dev/null 2>&1 \
        || say "No container named $agent exists yet. DatRail will wait for it and attach when it starts."
      ;;
  esac
fi
[ "$openshell_collector" = 0 ] || case $agent in openshell:*) ;; *) die "--openshell-collector goes with --agent openshell:SANDBOX" 2 ;; esac

# The name RailDash and Rail Center file the agent under: the container's
# (or sandbox's) name when it is a valid agent key, else that name made into
# one (lower case, other characters as '-', at most 64).
agent_key=""
if [ -n "$agent" ]; then
  base=${agent#openshell:}
  key=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9._-]/-/g' -e 's/^[^a-z0-9]*//' | cut -c1-64)
  [ "$key" = default ] && key=openshell-default
  [ -n "$key" ] || key=my-agent
  [ "$key" = "$base" ] || agent_key=$key
fi

# ------------------------------------------------------------- the settings
# .env holds the choices, so a later `docker compose up -d` in this directory
# starts the same stack. Only the lines this script owns are replaced.
set_env() { # set_env KEY [VALUE]: no VALUE removes the line
  local tmp
  tmp=$(mktemp "$dir/.env.XXXXXX")
  if [ -f .env ]; then grep -v "^$1=" .env > "$tmp" || true; fi
  [ $# -lt 2 ] || printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" .env
}
override=docker-compose.override.yml
marker="# Written by install.sh"
if [ -f "$override" ] && ! head -n 1 "$override" | grep -qF "$marker"; then
  die "$dir/$override exists and isn't install.sh's; move it aside, or set AGENT_CONTAINER in .env and run docker compose yourself (INSTALL.md#watch-your-own-agent)."
fi

step "Writing the settings to $dir/.env"
if [ "$demo" = 1 ]; then
  set_env AGENT_CONTAINER
  set_env AGENT_KEY
  set_env COMPOSE_PROFILES
  rm -f "$override"
  say "Watching the demo agent."
else
  # Leave the demo agent out: in a profile nobody starts, so `docker compose
  # up -d` here leaves it out too, as `--scale demo-agent=0` does once. A
  # demo agent an earlier install started goes first.
  docker compose rm -sf demo-agent > /dev/null 2>&1 || true
  cat > "$override" <<EOF
$marker for an agent of your own: the demo agent
# starts only if you ask for it (--profile demo). Delete this file, or run
# install.sh --demo, to bring it back.
services:
  demo-agent:
    profiles: [demo]
EOF
  set_env AGENT_CONTAINER "$agent"
  if [ -n "$agent_key" ]; then set_env AGENT_KEY "$agent_key"; else set_env AGENT_KEY; fi
  if [ "$openshell_collector" = 1 ]; then set_env COMPOSE_PROFILES openshell; else set_env COMPOSE_PROFILES; fi
  say "Watching $agent${agent_key:+, filed as $agent_key}."
fi
[ -z "$port" ] || set_env RAILDASH_PORT "$port"
port=$(sed -n 's/^RAILDASH_PORT=//p' .env 2> /dev/null | tail -n 1)
port=${port:-8000}

# ---------------------------------------------------------------- start it
step "Starting DatRail (the first run downloads two images, about 540 MB)"
# An OpenShell collector an earlier install started goes when it is no
# longer wanted: left behind, it holds RailDash's volume, so a later
# `docker compose down -v` couldn't delete it.
if [ "$openshell_collector" = 0 ]; then
  COMPOSE_PROFILES=openshell docker compose rm -sf openshell-collector > /dev/null 2>&1 || true
fi
docker compose up -d --remove-orphans
say "Waiting for RailDash..."
health=""
waited=0
while [ "$waited" -lt 180 ]; do
  id=$(docker compose ps -q raildash 2> /dev/null || true)
  health=$( [ -z "$id" ] || docker inspect --format '{{.State.Health.Status}}' "$id" 2> /dev/null || true)
  [ "$health" = healthy ] && break
  sleep 3
  waited=$((waited + 3))
done
[ "$health" = healthy ] || die "RailDash didn't become healthy in 3 minutes; \`docker compose logs raildash\` in $dir says why."
docker compose ps

# ----------------------------------------------------------- the agent itself
# Nothing to restart: RailMon attaches to the agent as it runs, and again
# whenever it restarts. What it can't see is the past.
if [ -n "$agent" ] && running "$agent"; then
  say ""
  say "No need to restart $agent: RailMon attaches to it while it runs."
  say "Its calls and the ports it listens on are seen from now. A file it opened only before now"
  say "(its configuration, read at start) appears once it opens that file again."
fi

# --------------------------------------------------------------- next steps
step "DatRail is running"
say "Open http://127.0.0.1:$port in a browser on this computer."
say ""
say "Next:"
say "  1. Let the agent do its normal work for a while. RailMon scans it every minute,"
say "     and its Agent Security Profile (ASP) appears in RailDash."
say "  2. In RailDash, lock that ASP as the agent's baseline. Anything it does later that"
say "     the baseline doesn't cover is shown as drift."
say "  3. Adopt the proposed Data Guardrail, which checks every upload, saved file, port and call."
say ""
say "The stack keeps running and restarts with Docker. In $dir:"
say "  docker compose logs -f     what it is doing"
say "  docker compose down        stop it (RailDash keeps its data)"
say "  docker compose down -v     stop it and delete the data"
say "Run install.sh again to watch another agent."
