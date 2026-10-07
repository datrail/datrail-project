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
- **`git`.** `make` is optional; the [Makefile](Makefile) only wraps
  `docker compose` commands.
- **Linux on x86_64 with a BTF-enabled kernel** (`/sys/kernel/btf/vmlinux`
  exists). See the platform table below.
- **Network access to GitHub** for the first build. The images are built from
  the components' source (see [Images](#images)).

### Platform support

| Platform | Works | Notes |
| --- | --- | --- |
| **Linux (x86_64, native)** | Yes | Real kernel with BTF; the probes see host processes. |
| **Windows, WSL2 with Docker Engine installed in the distro (x86_64)** | Yes | WSL2 runs a real Linux kernel with BTF; the probes see the distro's processes. |
| **Windows, WSL2 with Docker Desktop (x86_64)** | Partly | Containers run in Docker Desktop's own Linux VM, so the probes see only what runs inside that VM. The demo agent works; an agent running natively in your WSL distro is not visible, so run it in a container. |
| **macOS (Intel, Docker Desktop)** | Partly | Containers run in a Linux VM, so the probes see only what runs inside that VM. The demo agent works; an agent running natively on the Mac is not visible. |
| **Apple Silicon / arm64** | No | AgentSight, RailMon's TLS probe, publishes no arm64 build, so nothing is captured. |

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
make clean                 # also delete the built images and any leftovers
```

`docker compose down -v` removes only what the current `docker-compose.yml`
declares. It keeps the two built images (`datrail-railmon:local` and
`datrail-raildash:local`, about 540 MB together). It also keeps anything an
older version of this stack created: the version before 3 October 2026 used
the volumes `captures` and `raildash-db` and a `railmon` service, which
survive an upgrade by `git pull`. `make clean` removes all of it: orphaned
containers, every volume labelled with this Compose project, and the built
images. Without `make`, run the commands in the [Makefile](Makefile)'s
`clean` target. The older version's images are not this stack's, so `make
clean` leaves them: the published `ghcr.io/datrail/railmon` and
`ghcr.io/datrail/raildash`, or `railmon:local` and `raildash:local` if you
built with `make stack-local`. Remove those with `docker image rm` if nothing
else uses them.

## Settings

Set these in your shell or in a `.env` file next to `docker-compose.yml`.
All are optional.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_CONTAINER` | `datrail-demo-agent` | The container to watch. `railmon-listen` and `railmon-files` attach to it and `railmon-scan` scans it. |
| `AGENT_KEY` | the container name | The identity RailDash files ASPs under, when the agent has no deployment identity of its own (see [docs/glossary.md](docs/glossary.md#identity)). A container started by Compose is identified by its Compose project and service instead. |
| `COLLECT_TARGET` | `--comm datrail-demo` | Which processes `railmon collect` taps. It matches across the whole host, so make it specific to your agent: `--comm NAME`, `--pid PID`, `--uid UID`, or `--binary-path PATH` for an agent with its TLS library linked in statically. |
| `SCAN_INTERVAL` | `60` | Seconds between scans. |
| `RAIL_HOST_ID` | `datrail-local` | The name of this machine in every evidence bundle. |
| `RAILDASH_PORT` | `8000` | The local port RailDash is published on (always on `127.0.0.1`). |
| `RAILDASH_TOKEN` | unset | RailDash's local write token, if you want to choose it (see below). |
| `RAILMON_SRC`, `RAILDASH_SRC` | the GitHub repositories | Where to build each image from (see [Images](#images)). |
| `DEMO_INTERVAL` | `30` | Seconds between the demo agent's calls. |

### The RailDash token

Every RailDash route that changes ASP or baseline state, including the one
evidence bundles are delivered to, requires RailDash's local write token in an
`X-RailDash-Token` header. The dashboard page carries it for your browser.
RailDash also writes it to `raildash.db.token` beside its database, and
`railmon-scan` reads it from there (a read-only mount), so the stack needs
no token configuration.

RailDash keeps the token in that file across restarts, so `railmon-scan`
keeps delivering after either side restarts. Set `RAILDASH_TOKEN` to choose
the token yourself. A RailDash image built before stable-token support (an
old local build, or an old checkout in `RAILDASH_SRC`) generates a new token
on every start instead; if `docker compose logs railmon-scan` then shows
`HTTP 403` after RailDash restarted, rebuild with `docker compose up -d
--build` (updating that checkout first), or run
`docker compose restart railmon-scan`.

## Watch your own agent

Run your agent in a container, then point the stack at it and leave the demo
agent out:

```bash
AGENT_CONTAINER=my-agent COLLECT_TARGET="--comm my-agent-bin" \
  docker compose up -d --scale demo-agent=0
```

- `railmon-listen` waits for `my-agent` to start, so either can start
  first, and attaches again whenever it restarts. At each attach it records
  the sockets the agent is already listening on, then each one it opens.
- `railmon-files` follows `my-agent` the same way. It sees a file when it is
  opened, so a file the agent opened only before `railmon-files` attached
  (at its start, if the agent started first) is not listed.
- `COLLECT_TARGET` selects the agent's processes on the host. A process
  name (`--comm`) matches every process of that name on the machine, so pick
  one only your agent uses, or use `--pid` or `--uid`. An agent
  binary with its own statically linked TLS library needs
  `--binary-path /path/to/that/binary` as the host sees it.
- Lock a baseline in RailDash once the agent has done its normal work for a
  while. Anything it does later that the baseline does not cover is drift.

An agent not in a container can still be captured with `COLLECT_TARGET`; the
listen, files and scan services need a container to attach to.

## Images

Both images are built from source, from each repository's default branch:
`docker compose up -d` builds them the first time, and
`docker compose up -d --build` updates them. A git URL build context is
fetched with its submodules, which RailMon needs.

To build from local checkouts instead, clone them (RailMon with its
submodules):

```bash
git clone --recursive https://github.com/datrail/railmon.git
git clone https://github.com/datrail/raildash.git
RAILMON_SRC=../railmon RAILDASH_SRC=../raildash docker compose up -d --build
```

The published images (`ghcr.io/datrail/railmon:0.1.0` and
`ghcr.io/datrail/raildash:0.1.0`) predate interval scanning, `railmon listen`
and RailDash's evidence-bundle route, so they cannot run this stack. The
stack will switch to published images once a release contains these
features.

This repository's CI runs the same stack from both default branches on every
change and daily, and checks the walkthrough above end to end
([`tests/stack-acceptance.sh`](tests/stack-acceptance.sh)). A second job
follows [Watch your own agent](#watch-your-own-agent) with a `my-agent`
container started after the stack (`STACK_MODE=own-agent`).

## Troubleshooting

**`docker: command not found` in WSL.** With Docker Desktop: Desktop is not
running, or WSL integration is off for this distro (see [Prerequisites](#prerequisites)).
Right after Desktop starts, give the integration a moment to attach.

**No interactions appear.** Check `docker compose logs railmon-collect`. The
collector needs a privileged container, the host PID namespace, and an
x86_64 kernel with BTF. On macOS, only processes inside Docker Desktop's VM
are visible. For your own agent, check that `COLLECT_TARGET` matches its
processes.

**No ASPs appear.** Check `docker compose logs railmon-scan`. `container not
found` means `AGENT_CONTAINER` names a container that is not running;
`HTTP 403` means a stale token (see [The RailDash token](#the-raildash-token)).

**`observed_listeners` is `PARTIAL`, or drifts after a restart.** The listen
probe restarted, so sockets opened while it was down may be missing. RailMon
reports that as drift rather than "nothing new". Accept the new state once
you have checked it.

**The agent's listener is missing.** The RailMon image predates recording
the sockets an agent was already listening on when `railmon-listen`
attached (an old local build, or an old checkout in `RAILMON_SRC`). Rebuild
with `docker compose up -d --build`, updating that checkout first.

**A baseline drifts once after an upgrade, on `observed_file_access`.** A
stack from before 7 October 2026 ran no `railmon-files`, so its ASPs
reported `observed_file_access` as `BLIND`. Once the upgraded stack records
files, the attribute is `ANSWERED` and a baseline locked before the upgrade
shows drift on it. Check the files listed and accept the new state as the
new baseline; it happens once.

**`observed_file_access` drifts after the agent restarts.** A restarted agent
may open files under new names (a fresh temp directory, a new log file).
Randomly named files directly in `/tmp`, `/var/tmp`, `/dev/shm` or the
agent's `$TMPDIR` are folded into one templated path, so they do not churn;
other new names are drift, by design. Accept the new state once you have
checked it.

**Interactions appear twice.** Expected for the demo agent: both ends of its
HTTPS calls are tapped (see [Verify](#verify)).
