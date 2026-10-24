# Installing DatRail (RailMon + RailDash)

[README.md](README.md) has the short version. This page covers the details:
what the stack needs, every setting, watching your own agent, and what to do
when something looks wrong.

Everything runs locally. There is no cloud account and no sign-in, and
RailDash listens on `127.0.0.1` only.

## Prerequisites

- **Docker Engine with Compose v2.** Three RailMon containers run privileged
  in the host PID namespace (the eBPF probes need it), so your Docker daemon
  must allow privileged containers.
- **On Windows, a WSL2 distro with Docker in it.** Either install Docker
  Engine inside the distro, or use Docker Desktop with WSL integration on for
  that distro (Settings → Resources → WSL integration); the
  [platform table](#platform-support) shows what each one can watch. With
  Docker Desktop, the `docker` command exists inside the distro only while
  Desktop is running, and can take a moment to appear after Desktop starts.
  Run every command below inside that distro.
- **`git`, or just `curl`.** `docker-compose.yml` is the whole install, so
  downloading that one file is enough ([Without the
  repository](#without-the-repository)). `make` is optional; the
  [Makefile](Makefile) only wraps `docker compose` commands.
- **Linux on x86_64 or arm64 with a BTF-enabled kernel**
  (`/sys/kernel/btf/vmlinux` exists). On a Mac or with Docker Desktop, that
  is Docker Desktop's own Linux VM: `docker run --rm alpine ls
  /sys/kernel/btf/vmlinux` checks it. See the platform table below.
- **Network access to `ghcr.io`** for the first run, which pulls the
  [published images](#images), or to GitHub if you
  [build from source](#build-from-source).

### Platform support

| Platform | Works | Notes |
| --- | --- | --- |
| **Linux, native (x86_64 or arm64)** | Yes | Real kernel with BTF; the probes see host processes. CI runs the quick start on both architectures. |
| **Windows, WSL2 with Docker Engine installed in the distro (Intel/AMD x86_64)** | Yes | WSL2 runs a real Linux kernel with BTF; the probes see the distro's processes. |
| **Windows, WSL2 with Docker Desktop (Intel/AMD x86_64)** | Agents in containers | Containers run in Docker Desktop's own Linux VM, so the probes see only what runs inside that VM. The demo agent works; an agent running natively in your WSL distro is not visible, so run it in a container. An agent in an [OpenShell sandbox](#an-agent-in-an-openshell-sandbox) needs native Linux. |
| **macOS, Intel or Apple Silicon, with Docker Desktop** | Agents in containers (run on Apple Silicon; not yet on an Intel Mac) | Containers run in Docker Desktop's Linux VM (arm64 on Apple Silicon), so the probes see only what runs inside that VM: the demo agent and your own agent in a container, not an agent running natively on the Mac. The images are the ones CI runs on x86_64 and arm64 Linux, and CI's own-agent job uses Docker Desktop's containerd image store; Docker Desktop's VM kernel needs BTF (the check under Prerequisites). To check a Mac install, follow the [quick start](README.md#quick-start): `make test` runs on Linux only, since it checks the host's `/sys/kernel/btf/vmlinux`. An agent in an [OpenShell sandbox](#an-agent-in-an-openshell-sandbox) needs native Linux. |

## Run it

```bash
git clone https://github.com/datrail/datrail-project.git
cd datrail-project
docker compose up -d
```

Open <http://127.0.0.1:8000>. Six services start:

| Service | What it does |
| --- | --- |
| `raildash` | The dashboard and its SQLite database, on `127.0.0.1:8000`. |
| `railmon-collect` | `railmon collect`: captures the agent's TLS traffic and posts each request/response pair to RailDash as it happens. |
| `railmon-listen` | `railmon listen`: records every socket the agent opens to accept traffic, and who connects to it. |
| `railmon-files` | `railmon files`: records each file the agent's processes open, and whether to read, write or run it. Paths only, never contents. |
| `railmon-scan` | `railmon scan --interval`: scans the agent every `SCAN_INTERVAL` seconds and posts the evidence bundle to RailDash, where it becomes an ASP. |
| `demo-agent` | A stand-in agent (`datrail-demo-agent`) that serves HTTPS on `127.0.0.1:8443` and calls itself. |

Every service restarts on its own and delivers continuously. Nothing has to be
stopped, restarted or imported by hand, before or after you lock a baseline.

### Verify

A minute or two after `docker compose up -d`:

- `docker compose ps` shows all six services `Up`, and `raildash` `healthy`.
- The dashboard lists interactions: `POST` to `127.0.0.1:8443`, paths
  `/v1/demo` and `/v1/demo/other`, status `200`. Each call is captured twice,
  once as the client sent it and once as the server received it, because
  both ends are the demo agent's processes.
- The **Agent Security Profile alignment** panel has an ASP for
  `demo-agent`, with `observed_listeners` including port 8443 and
  `observed_file_access` listing the files the agent opened, among them its
  own `demo_client.py` (click **Inspect evidence** on the ASP to see them).
  RailMon rescans every minute,
  but a new ASP appears only when a scan finds something new.

The README's [drift walkthrough](README.md#what-you-see-in-raildash) shows the
rest.

### Stop and reset

```bash
docker compose down        # stop; RailDash's database and token are kept
docker compose down -v     # also delete them, for a fresh start
make clean                 # also delete the stack's images and any leftovers
```

`docker compose down -v` removes only what the current `docker-compose.yml`
declares. It keeps the stack's two images (the pinned
[published images](#images), or `datrail-railmon:local` and
`datrail-raildash:local` when built, about 540 MB together). It also keeps anything an
older version of this stack created: the version before 3 October 2026 used
the volumes `captures` and `raildash-db` and a `railmon` service, which
survive an upgrade by `git pull`. `make clean` removes all of it: orphaned
containers, every volume labelled with this Compose project, the pinned
published images, and `datrail-railmon:local` and `datrail-raildash:local`
if you built them. Without `make`, run the commands in the [Makefile](Makefile)'s
`clean` target. The older version's images are not this stack's, so `make
clean` leaves them: the published `ghcr.io/datrail/railmon` and
`ghcr.io/datrail/raildash` it ran, unless this stack runs them too, or
`railmon:local` and `raildash:local` if you built with `make stack-local`. Remove those with `docker image rm` if nothing
else uses them.

## Settings

Set these in your shell or in a `.env` file next to `docker-compose.yml`.
All are optional.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_CONTAINER` | `datrail-demo-agent` | The container to watch. `railmon-collect`, `railmon-listen` and `railmon-files` attach to it and `railmon-scan` scans it. |
| `AGENT_KEY` | the container name | The identity RailDash files ASPs under, when the agent has no deployment identity of its own (see [docs/glossary.md](docs/glossary.md#identity)). A container started by Compose is identified by its Compose project and service instead. |
| `COLLECT_TARGET` | unset | Only to choose the processes `railmon collect` taps yourself, instead of `AGENT_CONTAINER`'s: `--comm NAME`, `--pid PID`, `--uid UID`, or `--binary-path PATH`. These match across the whole host. |
| `SCAN_INTERVAL` | `60` | Seconds between scans. |
| `RAIL_HOST_ID` | `datrail-local` | The name of this machine in every evidence bundle. |
| `RAIL_CENTER_URL` | unset | A Rail Center to send every evidence bundle to as well (see [Sending bundles to Rail Center](#sending-bundles-to-rail-center)). Unset, no bundle leaves this machine. |
| `RAIL_AUTH_MODE`, `RAIL_AUTH_TOKEN`, `RAIL_AUTH_AUDIENCE` | `none` | The credential `railmon-scan` presents to Rail Center. Used only with `RAIL_CENTER_URL`. |
| `RAILDASH_PORT` | `8000` | The local port RailDash is published on (always on `127.0.0.1`). |
| `RAILDASH_TOKEN` | unset | RailDash's local write token, if you want to choose it (see below): at least 16 characters of `A-Z a-z 0-9 - _ . ~ + / =`, or RailDash does not start. |
| `RAILMON_IMAGE`, `RAILDASH_IMAGE` | `ghcr.io/datrail/railmon:0.1.0-m7`, `ghcr.io/datrail/raildash:0.2.0-rc.5` | The image each component runs (see [Images](#images)). |
| `RAILMON_SRC`, `RAILDASH_SRC` | the GitHub repositories | Where to build each image from, when you build (see [Build from source](#build-from-source)). |
| `DEMO_INTERVAL` | `30` | Seconds between the demo agent's calls. |

### The RailDash token

Every RailDash route that changes ASP or baseline state, including the one
evidence bundles are delivered to, requires RailDash's local write token in an
`X-RailDash-Token` header. The dashboard page carries it for your browser.
RailDash also writes it to `raildash.db.token` beside its database, and
`railmon-scan` and `railmon-collect` read it from there (a read-only mount),
so the stack needs no token configuration. The collector sends it with every
capture, which marks the capture as its own rather than anyone's who can
reach the webhook, and with a heartbeat every 60 seconds while it is attached
to the agent. A capture without the token is still shown.

RailDash keeps the token in that file across restarts, so `railmon-scan`
keeps delivering after either side restarts. Set `RAILDASH_TOKEN` to choose
the token yourself. A RailDash image built before stable-token support (an
old local build, or an old checkout in `RAILDASH_SRC`) generates a new token
on every start instead; if `docker compose logs railmon-scan` then shows
`HTTP 403` after RailDash restarted, rebuild with `make update` (updating
that checkout first), or run
`docker compose restart railmon-scan`.

### Sending bundles to Rail Center

The stack is local by default. To also send each evidence bundle to a Rail
Center, set `RAIL_CENTER_URL` to its base URL. `railmon-scan` then runs
`railmon scan --register`, which POSTs the same bundle it delivers to RailDash
to Rail Center's `/v1/agents/register`, every `SCAN_INTERVAL` seconds. An
unchanged bundle is re-sent as the same bytes, so Rail Center records a
duplicate rather than a new row.

```bash
RAIL_CENTER_URL=https://rail-center.example.com \
RAIL_AUTH_MODE=bearer RAIL_AUTH_TOKEN=... docker compose up -d
```

`RAIL_AUTH_MODE` is `none` (the default, which sends no credential),
`bearer` (sends `RAIL_AUTH_TOKEN`), or `gcp` (mints an identity token for
`RAIL_AUTH_AUDIENCE` from the host's service account, on Google Cloud).
Setting `RAIL_AUTH_TOKEN` with `none` is refused rather than ignored. The
two deliveries are independent: if Rail Center is unreachable or refuses the
bundle, `docker compose logs railmon-scan` says so, and RailDash still gets
every bundle.

Rail Center files the agent under its agent key (`AGENT_KEY`, or the
container name). It accepts a key of up to 64 characters that starts with
a lower-case letter or digit and continues with those, `.`, `_` or `-`.
For a container named otherwise, set `AGENT_KEY` to such a name; until
then registration fails on every scan and is logged.

## Watch your own agent

Run your agent in a container, then point the stack at it and leave the demo
agent out:

```bash
AGENT_CONTAINER=my-agent docker compose up -d --scale demo-agent=0
```

- `railmon-collect` finds the TLS library your agent uses: a `libssl` it
  loads, or one built into its executable, as in Node, Bun and other
  runtimes that bundle OpenSSL or BoringSSL. It captures the processes of
  `my-agent`'s container that share that process's session and TLS file,
  and attaches again whenever the container restarts, so there is no PID or
  path to look up. `docker compose logs railmon-collect` names the process
  and file it attached to. A second runtime in the same container, or a
  process that starts a session of its own, is not captured.

- `railmon-listen` waits for `my-agent` to start, so either can start
  first, and attaches again whenever it restarts. At each attach it records
  the sockets the agent is already listening on, then each one it opens.
- `railmon-files` follows `my-agent` the same way. It sees a file when it is
  opened, so a file the agent opened only before `railmon-files` attached
  (at its start, if the agent started first) is not listed.
- Lock a baseline in RailDash once the agent has done its normal work for a
  while. Anything it does later that the baseline does not cover is drift.

An agent not in a container can still be captured with `COLLECT_TARGET`; the
listen, files and scan services need a container to attach to. A process
name (`--comm`) matches every process of that name on the machine, and a
`--pid` changes when the agent restarts. A runtime that bundles its own TLS
(Node, for one) loads no `libssl`, so `--comm` alone captures nothing for
it: give `--binary-path` the executable's path as the collector sees it,
which for a process in a container is `/proc/<pid>/root/<path inside the
container>`, with `<pid>` as `docker top <container>` shows it.

The collector pairs each request with the next response on the same thread,
and the probe does not say which connection a read came from; a Node agent
does all its TLS on one thread. A read from another connection that arrives
between two chunks of a streamed (chunked) reply is kept out of that reply,
so the reply still comes through whole. Two HTTP connections busy on one
thread, a read landing in the middle of a chunk, or a reply that is not
chunked can still lose the reply. The request then appears after ten minutes
as an incomplete interaction, with no response, and `railmon-collect`'s log
counts it ([railmon#70](https://github.com/datrail/railmon/issues/70)).

### What a real agent looks like

The demo agent is small and predictable. A real one, such as OpenClaw on
Node, opens more files: `observed_file_access` is capped at 512 paths,
reads dropped first, so it shows as `PARTIAL`. Every written file is
still listed, so the Data Guardrail's Saved files rule is judged as usual
and can read held. A read the capped baseline couldn't list is not drift,
and neither is a file rewritten under a new uuid in its name: RailDash
compares it as that name with `*` for the uuid, and when at least three
letters or digits come before the uuid, the guardrail proposes and allows
it that way too. A file written under some other new random name each turn, outside
the temp directories that are folded (see
[Troubleshooting](#troubleshooting)), still drifts after every turn and is
a new Saved files row. A capped list makes Saved files read unverified
only when it lost something else too, such as a write past the cap or a
probe restart.

### An agent in an OpenShell sandbox

With [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)'s Docker
driver, each sandbox is a container. OpenShell asks of the image a non-root
user and a `/sandbox` directory that user can write, and of the sandbox's
policy a `network_policies` entry for each outside host the agent calls
([`tests/openshell/`](tests/openshell) has both for the demo agent). The
container's name carries an id OpenShell
generates, so look it up by the sandbox's name, and set `AGENT_KEY` so
RailDash keeps one name for the agent across new sandboxes:

```bash
openshell sandbox create --name my-agent --from <your image> --detach -- <your agent>
AGENT_CONTAINER=$(docker ps --format '{{.Names}}' \
  --filter label=openshell.ai/sandbox-name=my-agent \
  --filter label=openshell.ai/isolation-role=sandbox) \
AGENT_KEY=my-agent docker compose up -d --scale demo-agent=0
```

A new sandbox (`openshell sandbox delete` and `create` again) is a new
container: run the `docker compose up` line again so the stack follows it.

OpenShell's gateway runs as a user systemd service. On a machine with no
desktop session, such as a cloud VM you reach over SSH, turn on lingering
before installing OpenShell, or the gateway does not start:
`sudo loginctl enable-linger $USER`. CI installs OpenShell with
[`tests/openshell/install.sh`](tests/openshell/install.sh).

- OpenShell's supervisor makes every outside connection for the agent,
  and unless an endpoint sets `tls: skip` it terminates the agent's TLS
  with a CA of its own. The collector reads the agent's side either way,
  so each call appears as the agent made it, before OpenShell adds any
  provider credential.
- OpenShell opens every socket for the agent, so a port that was already
  listening when the stack started is listed under `openshell-sandb`, not
  the agent's own process name. `observed_listeners` also lists
  OpenShell's own DNS on `127.0.0.53:53` (TCP and UDP) with the agent's
  ports. The
  Data Guardrail's proposal shows them as `service_ports` rows. They are
  expected: allow them with the agent's own.
- Only the Docker driver is covered. Podman, Kubernetes and the MicroVM
  driver run the agent elsewhere.
- It doesn't run on Docker Desktop (a Mac, or Windows with Docker
  Desktop): the sandbox's supervisor looks for OpenShell's gateway at
  `127.0.0.1` and doesn't find it, so the sandbox doesn't start. Use
  native Linux. Docker Desktop still runs the rest of the stack.
- RailDash's Data Guardrail panel shows the sandbox's **Egress** as
  *Contained: it should not reach outside hosts itself; OpenShell
  enforces an allow-list*. It's read from Docker:
  OpenShell's sandbox labels together with a container that has no network
  of its own, no runtime socket and no privilege. The allow-list itself
  stays inside OpenShell, so datRail doesn't show what's on it. Because the
  baseline is contained, the proposed guardrail requires containment, so a
  sandbox that loses it is flagged.

This repository's CI runs this with OpenShell 0.1.3 and the demo agent
(`STACK_MODE=openshell`): the same walk as the own-agent job, then a call
to `api.github.com` through OpenShell's supervisor.

## Images

Each component runs a fixed published tag from `ghcr.io/datrail`, pinned in
`docker-compose.yml`. RailMon and RailDash carry their own tags:

| Component | Image |
| --- | --- |
| RailMon | `ghcr.io/datrail/railmon:0.1.0-m7` |
| RailDash | `ghcr.io/datrail/raildash:0.2.0-rc.5` |

`docker compose up -d` pulls them the first time. A newer version of this
file pins newer tags; `git pull` (or download the file again) and run
`docker compose up -d`. To run another published tag, name it:

```bash
export RAILMON_IMAGE=ghcr.io/datrail/railmon:<tag> RAILDASH_IMAGE=ghcr.io/datrail/raildash:<tag>
docker compose up -d
```

An image has to be at least as new as this file. The `0.1.0` images
predate interval scanning, `railmon listen` and RailDash's evidence-bundle
route, so they can't run this stack. RailMon's images can from `0.1.0-m4`
on, RailDash's from `0.2.0-rc.1`. Name a version tag rather than `latest`,
which can be older than this file.

### Build from source

To run each repository's default branch instead, build under local names:

```bash
make update
# which is:
RAILMON_IMAGE=datrail-railmon:local RAILDASH_IMAGE=datrail-raildash:local docker compose up -d --build
```

Keep both names set (in your shell or `.env`) for later `docker compose`
commands, or they go back to the pinned tags. Don't use `--build` without
them: Compose would tag the build with the published name. A git URL build
context is fetched with its submodules, which RailMon needs. To build from
local checkouts instead, clone them (RailMon with its submodules):

```bash
git clone --recursive https://github.com/datrail/railmon.git
git clone https://github.com/datrail/raildash.git
RAILMON_SRC=../railmon RAILDASH_SRC=../raildash \
RAILMON_IMAGE=datrail-railmon:local RAILDASH_IMAGE=datrail-raildash:local docker compose up -d --build
```

### Without the repository

`docker-compose.yml` reads nothing else from this repository: the build
contexts are git URLs and every volume is a named one. So one file is the
whole install:

```bash
mkdir datrail && cd datrail
curl -fsSLO https://raw.githubusercontent.com/datrail/datrail-project/master/docker-compose.yml
docker compose up -d
```

The `docker compose` commands in this page work the same from that
directory, and settings go in your shell or a `.env` file beside the
downloaded file. There is no Makefile there: `make clean` is
`docker compose down -v --remove-orphans --rmi all`. Compose names the
project after the directory, so a stack started here doesn't share
RailDash's database with one started from a clone. CI checks that the file
reads nothing from its checkout.

### What CI proves

This repository's CI runs the install exactly as pinned, pulling both
published images and building nothing (`STACK_IMAGES=pinned`), on every
change and daily. It also runs the same stack built from both default
branches, so a change there that would break the next pin shows first, and
checks the walkthrough above end to end
([`tests/stack-acceptance.sh`](tests/stack-acceptance.sh)). A second job
follows [Watch your own agent](#watch-your-own-agent) with a `my-agent`
container started after the stack (`STACK_MODE=own-agent`), on Docker's
containerd image store, the one Docker Desktop uses. A third runs the
quick start on a native arm64 runner.

## Troubleshooting

**`docker: command not found` in WSL.** With Docker Desktop: Desktop is not
running, or WSL integration is off for this distro (see [Prerequisites](#prerequisites)).
Right after Desktop starts, give the integration a moment to attach.

**No interactions appear.** Check `docker compose logs railmon-collect`. The
collector needs a privileged container, the host PID namespace, and an
x86_64 or arm64 kernel with BTF. On macOS, only processes inside Docker Desktop's VM
are visible. For your own agent, `docker compose logs railmon-collect` says
which process and TLS file it attached to, or that none in the container
uses TLS yet. With `COLLECT_TARGET` set, check that it matches the agent's
processes.

**No ASPs appear.** Check `docker compose logs railmon-scan`. `docker
inspect failed for container: <name>` most often means `AGENT_CONTAINER`
names a container that does not exist (check `docker ps -a`); otherwise check
that the Docker socket is mounted and reachable;
`HTTP 403` means a stale token (see [The RailDash token](#the-raildash-token)).

**`observed_listeners` or `observed_file_access` is `PARTIAL`, or drifts
after a restart.** The listen or files probe restarted (as it does when the
agent restarts), so sockets or files opened while it was down may be
missing. RailMon reports that as drift rather than "nothing new". Accept the
new state once you have checked it.

**The agent's listener is missing.** The RailMon image predates recording
the sockets an agent was already listening on when `railmon-listen`
attached (an old local build, or an old checkout in `RAILMON_SRC`). Rebuild
with `make update` (see [Build from source](#build-from-source)), updating
that checkout first, or go back to the pinned images.

**After an upgrade, ASPs show Comparison unavailable, reason
`CONTRACT_MISMATCH`.** Each
time RailMon's evidence changes shape it writes a new rule pack, and RailDash
doesn't compare a baseline from an older pack with the new ASPs at all,
rather than reporting each change as drift. A stack from before 7 October
2026 ran no `railmon-files` and wrote pack 6 or earlier. Pack 7 lists
`/proc/<pid>` paths as `/proc/*/`, and pack 8 (8 October 2026) adds the
agent's type, owner, LLM provider, sandbox type and system and user info.
Pack 9 (9 October 2026 UTC) adds `agent_instance`, where this copy runs:
the agent container's hostname, id and host pid, and the scan's own fqdn,
pid and working directory. RailDash leaves its value out of drift, so a new
hostname, container id or pid on its own is not drift. Pack 10 (11 October
2026 UTC) folds Python's bytecode-cache writes into `<dir>/__pycache__/*.pyc`.
Pack 11 (11 October 2026) adds `egress_containment`, whether the agent's
egress is contained as Docker shows it, and `egress_proxy_declared`, the proxy
its environment declares. Pack 12 (23 October 2026) takes the Docker user
from the image's configured user, records each MCP server's tool allow
lists, no longer lists GPG fingerprints or token budgets as credentials,
and reads a config holding `NaN` or `Infinity` as `PARSE_FAILED`. Pack 13
(23 October 2026) records listening sockets, peers and file opens with
AgentSight's process probe and names that probe in each of those
attributes; its TLS capture, behind `observed_destinations`, moves to
AgentSight v1.0.35 too. Check the
newest ASP's evidence and lock it as the new baseline; it happens once per
upgrade.

**A Codex agent's guardrail turns Violated or Unverified after upgrading to
RailDash `0.2.0-rc.4`.** From that version on, RailDash reads the MCP calls
Codex makes from inside its code-mode `exec` tool, which it couldn't see
before. A call to a server the guardrail doesn't allow is now a violation,
and a script that reaches a tool through a name it doesn't spell keeps the
rules Unverified for a while. If the server belongs there, use **Allow this**
on its row.

**`observed_file_access` lists new paths after the agent restarts.** A
restarted agent may open files under new names (a new log file, a fresh
directory of its own). A randomly named temp file under `/tmp`, `/var/tmp`
or `/dev/shm`, or directly in the agent's `$TMPDIR`, is folded into one
templated path, so it does not churn. A fixed name inside a randomly named
directory (`mktemp -d`) is not folded, and other new names are drift, by
design. Accept the new state once you have
checked it.

**Interactions appear twice.** Expected for the demo agent: both ends of its
HTTPS calls are tapped (see [Verify](#verify)).
