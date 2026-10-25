# DatRail on a Mac, step by step

A first install on a Mac with Docker Desktop, up to seeing drift in RailDash. For Windows, see [setup-windows.md](setup-windows.md). For every setting and option, see [INSTALL.md](../INSTALL.md).

## What you end up with

DatRail running on your Mac: RailMon watching a demo AI agent, and the RailDash dashboard open in your browser at http://127.0.0.1:8000.

It runs in Docker Desktop. Docker Desktop runs a small Linux machine inside your Mac, and DatRail runs in there. That decides what it can watch:

- **It can watch** the demo agent, and your own agent if it runs in a Docker container.
- **It cannot watch** an agent running directly on the Mac (outside Docker), because RailMon only sees inside Docker's Linux machine.

**Not on a Mac:** an agent in an OpenShell sandbox needs native Linux ([INSTALL.md](../INSTALL.md#an-agent-in-an-openshell-sandbox)).

## Before you start

- A Mac with Apple Silicon. **Intel Macs are expected to work but have not been tested yet.**
- Administrator rights, for the Docker Desktop install
- About 10 GB of free disk space
- An internet connection: the first start downloads DatRail's images

Time: about 15 minutes the first time, most of it installing Docker Desktop. DatRail itself starts in under a minute.

## Step 1: Install Docker Desktop

1. Download Docker Desktop for Mac from https://www.docker.com/products/docker-desktop/ . Pick the version for your chip: **Apple Silicon** or **Intel** (Apple menu, About This Mac, shows which you have).
2. Open the downloaded file, drag Docker to Applications, and start it.
3. Wait until Docker Desktop says the engine is running.
4. Leave the settings at their defaults ("Use containerd for pulling and storing images" on, which is the default in current versions).

Docker Desktop has to be running whenever you use DatRail.

## Step 2: Check that everything is ready

Open **Terminal** (Applications, Utilities, Terminal). Every command from here on runs there.

```bash
docker version
```

Shows both a Client and a Server section. If it says it cannot connect to the Docker daemon, Docker Desktop is not running yet.

```bash
docker compose version
```

Shows Docker Compose v2 or later.

```bash
docker run --rm alpine ls /sys/kernel/btf/vmlinux
```

Prints `/sys/kernel/btf/vmlinux`. This checks that Docker Desktop's Linux machine has what RailMon's probes need (BTF). The file only exists inside Docker, not on the Mac itself, so always check it through `docker run` like this.

```bash
docker run --rm --privileged hello-world
```

Prints "Hello from Docker!". RailMon needs privileged containers, and this checks they are allowed.

```bash
git --version
```

Prints a version. If the Mac offers to install the command line developer tools instead, accept, wait for it to finish, and run it again.

## Step 3: Get DatRail

```bash
cd ~
git clone https://github.com/datrail/datrail-project.git
cd datrail-project
```

**If you cloned datrail-project before,** do not reuse an old copy without updating it: clone fresh, or in the old folder run `git pull`. Older versions asked for `RAILDASH_TAG` and `RAILMON_TAG` and fail with these steps.

## Step 4: Start it

```bash
docker compose up -d
```

The first time, this downloads the published RailMon and RailDash images, each pinned to a fixed version and built for your chip: under a minute on a normal connection. Later starts take seconds.

Then check:

```bash
docker compose ps
```

Six services are `Up`, and `raildash` says `(healthy)`. If it still says `starting`, wait a minute and run it again.

**To update later,** get the newest version of datrail-project and start again. The new file pins newer images, and Docker downloads them:

```bash
git pull
docker compose up -d
```

## Step 5: Open the dashboard

In your browser, open http://127.0.0.1:8000 .

Within a minute or two you should see:

- **Interactions**: the demo agent's calls to `127.0.0.1:8443`: `POST /v1/demo` and `/v1/demo/other`, and calls to its tool server at `/mcp` (`POST`, `GET`, and a `DELETE` that ends each session with `204`). Each call shows twice, once from each side, because the demo agent calls itself.
- **Agent Security Profile alignment**: a profile (ASP) for the demo agent. Click **Inspect evidence** to see its open port 8443 and the files it opened.

That is a working install.

**Optional, the full automated check.** `make test` runs CI's acceptance check: it starts its own copy of the stack, drives the drift and guardrail steps, and removes that copy at the end. It needs `jq` (`jq --version`; if there is none, `brew install jq`), and your own stack stopped first, because the containers' names are fixed. `docker compose down` keeps your stack's data:

```bash
docker compose down
STACK_IMAGES=pinned make test
docker compose up -d
```

`STACK_IMAGES=pinned` checks the images your install runs. Without it, `make test` builds both images from source first, which takes longer. It takes about 5 to 10 minutes and ends with every check `ok`. The end removes the images it used, so the next `docker compose up -d` downloads them again.

## Step 6: Try the demo

1. **Lock a baseline.** Wait until there are two profiles under "Agent Security Profile alignment" (the second arrives a minute after the first, with file access). On the newest one, click **Lock this as your alignment baseline**. The status reads **ALIGNED, v1.0 (active)**.
2. **Make the demo agent open a new port:**

   ```bash
   docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1
   ```

   Within a minute RailDash shows **DRIFT DETECTED**, and `observed_listeners` has gained port 9000.

The rest of the walk (the Data Guardrail, then breaking it) is in the README, [What you see in RailDash](../README.md#what-you-see-in-raildash).

## Stop and start over

```bash
docker compose down        # stop; the dashboard's data is kept
docker compose down -v     # stop and delete the data, for a fresh start
```

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "Cannot connect to the Docker daemon" | Docker Desktop is not running. Start it and wait until the engine is running. |
| `ls: /sys/kernel/btf/vmlinux: No such file or directory` | You ran the check on the Mac itself. Run it through Docker: `docker run --rm alpine ls /sys/kernel/btf/vmlinux` (Step 2). |
| `make test` says a container named `datrail-demo-agent` exists | Your own stack is still running. Stop it with `docker compose down` (its data is kept) and run `make test` again. |
| `make test needs jq on PATH` | Install it with `brew install jq`, or put a `jq` binary on your `PATH`. |
| An error asking for `RAILDASH_TAG` or `RAILMON_TAG` | You are in an old copy of datrail-project. Clone fresh, or `git pull` (Step 3). |
| Port 8000 is already in use | Start with another port: `RAILDASH_PORT=18000 docker compose up -d`, then open http://127.0.0.1:18000 . |
| The first `docker compose up -d` takes a few minutes | It is downloading the images; a slow connection takes longer. Later starts take seconds. |
| Your own agent shows no interactions | It has to run in a Docker container; an agent running directly on the Mac is not visible. `docker compose logs railmon-collect` says what the collector attached to. |

More in [INSTALL.md, Troubleshooting](../INSTALL.md#troubleshooting).
