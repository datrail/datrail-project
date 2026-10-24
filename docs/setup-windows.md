# DatRail on Windows, step by step

A first install on Windows 11, from installing WSL2 to seeing drift in RailDash. For a Mac, see [setup-mac.md](setup-mac.md). For every setting and option, see [INSTALL.md](../INSTALL.md).

## What you end up with

DatRail running on your Windows PC: RailMon watching a demo AI agent, and the RailDash dashboard open in your browser at http://127.0.0.1:8000.

It runs inside WSL2, the Linux that Windows can run alongside itself, using Docker Desktop. Docker Desktop runs containers in its own small Linux machine, so DatRail watches agents running in Docker containers: the demo agent, and your own agent if you run it in a container. To watch an agent running directly in your WSL distro instead, install Docker Engine in the distro (see [INSTALL.md](../INSTALL.md#prerequisites)).

**Not on Windows:** an agent in an OpenShell sandbox needs native Linux ([INSTALL.md](../INSTALL.md#an-agent-in-an-openshell-sandbox)).

## Before you start

- Windows 11 (Windows 10 21H2 or later also works for WSL2)
- Administrator rights on the PC, for the installs
- About 10 GB of free disk space
- An internet connection: the first start downloads DatRail's images

Time: about 20 minutes the first time, most of it installing WSL2 and Docker Desktop. DatRail itself starts in under a minute.

## Step 1: Install WSL2 and Ubuntu

1. Open **PowerShell as administrator** (Start menu, type PowerShell, right-click, Run as administrator).
2. Run:

   ```powershell
   wsl --install -d Ubuntu
   ```

3. Restart the PC when asked.
4. After the restart an **Ubuntu** window opens. Choose a Linux user name and password. This is your Linux user, separate from your Windows login.
5. Check it is WSL version 2. In PowerShell:

   ```powershell
   wsl -l -v
   ```

   The `VERSION` column next to Ubuntu must say `2`.

## Step 2: Install Docker Desktop and connect it to Ubuntu

1. Download Docker Desktop for Windows from https://www.docker.com/products/docker-desktop/ and install it with the default options.
2. Start Docker Desktop and wait until it says the engine is running.
3. Open **Settings**:
   - **General**: "Use the WSL 2 based engine" is ticked.
   - **Resources, then WSL integration**: turn on the switch for **Ubuntu**.
4. Click **Apply and restart**.

Docker Desktop has to be running whenever you use DatRail. If it is closed, the `docker` command disappears from Ubuntu.

## Step 3: Check that everything is ready

Open **Ubuntu** from the Start menu. Every command from here on runs in that Ubuntu window, not in PowerShell.

```bash
docker version
```

Shows both a Client and a Server section. If you get "command not found", see Troubleshooting.

```bash
docker compose version
```

Shows Docker Compose v2 or later.

```bash
docker run --rm alpine ls /sys/kernel/btf/vmlinux
```

Prints `/sys/kernel/btf/vmlinux`. This checks that Docker's Linux kernel has what RailMon's probes need (BTF).

```bash
docker run --rm --privileged hello-world
```

Prints "Hello from Docker!". RailMon needs privileged containers, and this checks they are allowed.

## Step 4: Get DatRail

In Ubuntu, from your Linux home folder:

```bash
cd ~
git clone https://github.com/datrail/datrail-project.git
cd datrail-project
```

Keep it in your Linux home (`~`), not under `/mnt/c/...` (your Windows drive), where everything runs much slower.

**If you cloned datrail-project before,** do not reuse an old copy without updating it: clone fresh, or in the old folder run `git pull`. Older versions asked for `RAILDASH_TAG` and `RAILMON_TAG` and fail with these steps.

## Step 5: Start it

```bash
docker compose up -d
```

The first time, this downloads the published RailMon and RailDash images, each pinned to a fixed version: under a minute on a normal connection. Later starts take seconds.

Then check:

```bash
docker compose ps
```

Six services are `Up`, and `raildash` says `(healthy)`. If `raildash` still says `starting`, wait a minute and run it again.

**To update later,** get the newest version of datrail-project and start again. The new file pins newer images, and Docker downloads them:

```bash
git pull
docker compose up -d
```

## Step 6: Open the dashboard

In your **Windows** browser, open http://127.0.0.1:8000 .

Within a minute or two you should see:

- **Interactions**: the demo agent's calls to `127.0.0.1:8443`: `POST /v1/demo` and `/v1/demo/other`, and calls to its tool server at `/mcp` (`POST`, `GET`, and a `DELETE` that ends each session with `204`). Each call shows twice, once from each side, because the demo agent calls itself.
- **Agent Security Profile alignment**: a profile (ASP) for the demo agent. Click **Inspect evidence** to see its open port 8443 and the files it opened.

That is a working install.

## Step 7: Try the demo

1. **Lock a baseline.** Wait until there are two profiles under "Agent Security Profile alignment" (the second arrives a minute after the first, with file access). On the newest one, click **Lock this as your alignment baseline**. The status reads **ALIGNED, v1.0 (active)**. Drift can only be detected once a baseline is locked.
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
| `docker: command not found` in Ubuntu | Docker Desktop is not running, or WSL integration is off for Ubuntu (Step 2). Right after Docker Desktop starts, wait a few seconds and try again. |
| An error asking for `RAILDASH_TAG` or `RAILMON_TAG` | You are in an old copy of datrail-project. Clone fresh, or `git pull` (Step 4). |
| Port 8000 is already in use | Start with another port: `RAILDASH_PORT=18000 docker compose up -d`, then open http://127.0.0.1:18000 . |
| The first `docker compose up -d` takes a few minutes | It is downloading the images; a slow connection takes longer. Later starts take seconds. |
| Another DatRail is already running (port 8000 taken, or `datrail-demo-agent` already exists) | Stop the old one first: in its folder, `docker compose down` (or `down -v` to also delete its data). |
| No interactions appear | `docker compose logs railmon-collect` shows what the collector attached to. Check Docker Desktop is running and the BTF check in Step 3 passed. |

More in [INSTALL.md, Troubleshooting](../INSTALL.md#troubleshooting).
