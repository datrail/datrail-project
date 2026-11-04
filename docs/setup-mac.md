# Install DatRail on a Mac

DatRail is an open-source tool for people who want to keep an eye on what their own AI agent does with their data, on their own computer. This guide takes you from nothing to DatRail watching an agent on your Mac, one step at a time. It shows what you should see after each step, so you can tell it worked before you move on.

It takes about 15 minutes the first time, most of it installing Docker Desktop. Using Windows instead? See [Install DatRail on Windows](setup-windows.md).

## What you get

DatRail watches what an AI agent does: the services it calls, the files it opens and the ports it listens on. It learns the agent's normal behavior and tells you when the agent does something new. You see it all in a dashboard in your web browser.

DatRail has two parts, and both run on your Mac:

- **RailMon**, the monitor, which watches the agent
- **RailDash**, the dashboard, which you open in your browser at http://127.0.0.1:8000

> [!IMPORTANT]
> **Your agent needs to run in a Docker container.** DatRail is built for agents that already run in a sandbox, such as a Docker container. It can't see an agent running directly on your Mac, such as an app or a program started in Terminal. DatRail watches an agent inside its sandbox. It doesn't sandbox the agent for you. No agent in a container yet? You can try DatRail with its demo agent first.

### Words you'll see

| Word | What it means |
| --- | --- |
| **Container** | A sealed-off space where a program runs, separate from the rest of your Mac. Docker Desktop runs containers. |
| **Profile (ASP)** | DatRail's record of what the agent did: the ports it listened on and the files it opened. RailDash calls it an Agent Security Profile, or ASP. |
| **Baseline** | A profile you choose as "this is normal for my agent". |
| **Drift** | Something the agent did that its baseline doesn't cover. |
| **Data Guardrail** | Rules for what the agent may do with data: uploads, saved files, ports and calls. You approve every rule. |

The [glossary](glossary.md) explains every term in more detail.

## Before you start

You need:

- **A Mac with Apple Silicon** (M1 or later). Intel Macs should work but haven't been tested yet. To check: open the Apple menu (top left of the screen), choose **About This Mac**, and look at **Chip**. "Apple M1" or later is Apple Silicon. "Intel" is an Intel Mac.
- **A recent version of macOS.** Docker Desktop supports the current macOS and the two before it. **About This Mac** shows your version.
- **Administrator rights**: you need to type your Mac's password once, while installing Docker Desktop.
- **About 10 GB of free disk space**: Docker Desktop and DatRail together.
- **An internet connection**, for the downloads.

## Step 1: Install Docker Desktop

DatRail runs inside Docker Desktop, a free app that runs containers on your Mac. If you already have it, skip to "Check that it's running" below.

1. Go to https://www.docker.com/products/docker-desktop/ and click **Download Docker Desktop**. Choose **Mac with Apple Silicon** or **Mac with Intel chip**, to match the chip you found above.
2. Open the downloaded file, `Docker.dmg`. A window opens with the Docker whale and your Applications folder.
3. Drag the Docker whale onto the Applications folder. Wait for it to copy.
4. Open your **Applications** folder and double-click **Docker**. If your Mac asks whether you're sure you want to open an app downloaded from the internet, click **Open**.
5. Docker Desktop asks you to accept its service agreement. Read it and click **Accept**.
6. If it asks how to finish setting up, choose **Use recommended settings** and type your Mac's password when asked.
7. It may ask you to sign in to a Docker account or answer a short survey. Neither is needed for DatRail: you can choose **Skip** for both.

**Check that it's running.** Look for the Docker whale icon in the menu bar at the top of your screen. In the Docker Desktop window, the bottom left corner should say **Engine running**, in green. The first start can take a minute.

Docker Desktop has to be running whenever you use DatRail. If you quit it, DatRail stops too, and it starts again when you open Docker Desktop.

## Step 2: Open Terminal

You install DatRail by typing one command into Terminal, the Mac's command window.

1. Press **Cmd + Space** to open Spotlight search, type **Terminal**, and press **Return**.
2. A window opens with a line ending in `%`, such as `yourname@MacBook-Pro ~ %`. This is where you type commands.

**How to run a command from this guide:** copy it (each command box has a copy button on its top right), click in the Terminal window, press **Cmd + V** to paste, then press **Return**.

**Check that Terminal can reach Docker.** Run:

```bash
docker version
```

You should see two sections, **Client** and **Server**. If it says `command not found: docker`, Docker Desktop isn't installed yet (Step 1). If it says it cannot connect to the Docker daemon, Docker Desktop isn't running yet: open it and wait for **Engine running**. If you installed Docker Desktop with Terminal already open, close Terminal and open it again.

## Step 3: Find your agent's container (skip if you're trying the demo agent)

The installer lists the containers running now, and you pick your agent from that list. So, before you start the installer:

1. Make sure your agent's container is running.
2. Find its name. In Docker Desktop, click **Containers** on the left: the **Name** column lists each container. Or, in Terminal, run:

   ```bash
   docker ps --format '{{.Names}}'
   ```

   It prints one name per line, such as `my-agent`.

If your agent's container isn't running right now, you can still type its name in the installer (option `c`), and DatRail attaches to it when it starts.

## Step 4: Install DatRail

In Terminal, run:

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash
```

This downloads DatRail's installer and runs it. It adds a `datrail` folder to your home folder and runs DatRail's containers in Docker Desktop.

### 4.1 It checks your Mac

First it prints:

```text
==> Checking that this machine can run DatRail
Docker aarch64, Docker Desktop: OK
Note: with Docker Desktop, DatRail sees only agents running in Docker containers, not one running directly on this computer.
```

On an Intel Mac, `aarch64` reads `x86_64`. If you see a message starting with `install.sh:` instead, the check found a problem: see [If something goes wrong](#if-something-goes-wrong).

### 4.2 It asks which agent to watch

```text
==> Which agent should DatRail watch?
Containers running now:
   1) my-agent   (python:3.12-slim, Up 10 minutes)
   d) the demo agent, to try DatRail first
   o) an agent in an OpenShell sandbox that isn't running yet (you'll type its name)
   c) a container that isn't running yet (you'll type its name)
   n) my agent doesn't run in a container
Your choice:
```

Your list shows your own containers in place of `my-agent`. Type one choice and press **Return**:

| Type | To |
| --- | --- |
| A number, such as `1` | Watch that container, your agent. It keeps running: there's no need to restart it. |
| `d` | Try DatRail with its demo agent: a small agent that comes with DatRail and calls itself every 30 seconds. This guide's later steps show what it does. |
| `c` | Watch a container that isn't running yet. Type its name when asked. DatRail attaches to it when it starts. |
| `n` | Stop here if your agent doesn't run in a container. The installer explains what to do and ends without installing anything. |
| `o` | Not for a Mac: OpenShell sandboxes need a Linux computer. |

You can watch one agent at a time. To switch later, run the install command again.

### 4.3 It downloads and starts DatRail

```text
==> Writing the settings to /Users/yourname/datrail/.env
Watching my-agent.

==> Starting DatRail (the first run downloads two images, about 540 MB)
```

The download takes about a minute on a normal connection, and Terminal shows its progress. Then:

```text
Waiting for RailDash...
```

and a short table of DatRail's parts, each one `Up`. If you picked your own agent, it also tells you that the agent doesn't need a restart. A file the agent opened before DatRail started, such as its configuration, shows up once the agent opens that file again.

### 4.4 It's running

The installer ends with:

```text
==> DatRail is running
Open http://127.0.0.1:8000 in a browser on this computer.
```

DatRail is installed. Its files are in a folder called `datrail` in your home folder. In Finder, choose **Go**, then **Home**, to find it. You don't need to open or change anything in there.

## Step 5: Open the dashboard

In your web browser, go to http://127.0.0.1:8000 . This page lives on your Mac, so it only works on this computer.

Within a few minutes you should see two things:

- **Interactions**: every call the agent makes, with where it went, the method, the path and the result. The demo agent's calls go to itself, at `127.0.0.1:8443`, so each one shows twice, once from each side.
- **Agent Security Profile alignment**: the agent's profiles. The first one appears within a few minutes, with the ports the agent listens on and the files it opened. Click **Inspect evidence** on a profile to see them.

RailMon checks the agent every minute. A new profile appears only when it finds something new, so an agent that's sitting idle shows little. Let your agent do its normal work.

## Step 6: Lock a baseline

A baseline tells DatRail what's normal for your agent.

1. **Let the agent do its normal work for a while**, so its profile covers what it usually does. With the demo agent, wait until there are two profiles under **Agent Security Profile alignment**. The second arrives about a minute after the first, with the files the agent opened.
2. **On the newest profile, click Lock this as your alignment baseline.** The status changes to **ALIGNED, v1.0 (active)**.

From now on, DatRail compares everything the agent does with this baseline.

**See drift with the demo agent.** Make it open a port it didn't have before. In Terminal:

```bash
docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1
```

Within a minute, RailDash shows **DRIFT DETECTED**. Under the drift, `observed_listeners` lists the new port, 9000. That's DatRail noticing something new.

With your own agent, drift appears the same way when it does something its baseline doesn't cover. You can accept the new behavior as a new baseline, or switch back to an earlier one.

## Step 7: Adopt a Data Guardrail

Once a baseline is locked, the **Data Guardrail** panel proposes rules for the agent based on it: what the agent already did is allowed. It shows every rule before you approve it, and lists what would break the rules today.

1. **Read the proposal**, then click **Adopt**.
2. **Within a minute, anything outside the rules shows as a row.** With the demo agent there are two, both under **Service ports**: its own port 8443, and port 9000, still open from the drift step.
3. **Decide on each row:**
   - **Allow this** adds it to the rules, as a new version of the guardrail. Use it for something the agent is meant to do. With the demo agent, click **Allow all 2** under Service ports to allow both ports at once.
   - **Acknowledge** clears the row for now. It comes back if the same thing happens again.
4. **After the next check, a minute or two later, the agent reads Held**: it's inside its rules.

**See a broken rule with the demo agent.** Make it save a file its rules don't allow:

```bash
docker exec datrail-demo-agent sh -c 'mkdir -p /data && echo report > /data/report.zip'
```

Within a minute or two the agent reads **Violated**, with `/data/report.zip` under **Saved files**.

From the same panel you can edit the rules, switch to an earlier version, or turn the guardrail off. [What you see in RailDash](../README.md#what-you-see-in-raildash) goes further: uploads, calls to unknown hosts, and what each tool may do with data.

## Using DatRail day to day

DatRail keeps running in the background and starts again whenever Docker Desktop does. To manage it, open Terminal and go to its folder first:

```bash
cd ~/datrail
```

Then:

| To | Run |
| --- | --- |
| Check that it's running | `docker compose ps` (each part reads `Up`) |
| See what it's doing | `docker compose logs -f` (press **Ctrl + C** to stop watching) |
| Stop it (its data is kept) | `docker compose down` |
| Start it again | `docker compose up -d` |
| Watch a different agent | Run the install command from Step 4 again |
| Update to the latest version | Run the install command from Step 4 again. It keeps your data. |
| Remove it completely | `docker compose down -v --rmi all`, then `cd ~ && rm -rf ~/datrail` |

Removing it deletes DatRail's data and its downloads. It never touches your agent or its container. Docker Desktop stays installed. Remove it like any other app if you no longer need it.

## Other ways to install

- **Let your AI agent install it.** Tell your agent: *"Read https://raw.githubusercontent.com/datrail/datrail-project/master/docs/agent-install.md and install DatRail for me."* That page has it ask you before anything that needs full control of your Mac, and it never changes your agent.
- **Every setting and option,** including building DatRail from source, is in [INSTALL.md](../INSTALL.md).

## If something goes wrong

| What you see | What to do |
| --- | --- |
| `command not found: docker` | Docker Desktop isn't installed (Step 1). If you just installed it, close Terminal and open it again. |
| `install.sh: Docker isn't installed` | The same: install Docker Desktop (Step 1), then run the install command again. |
| `install.sh: Docker is installed but not running` | Open Docker Desktop, wait until it says **Engine running**, then run the install command again. |
| `install.sh: Docker can't run a privileged container with BTF` | Update Docker Desktop to its latest version (Docker menu in the menu bar, **Check for updates**), keep its default settings, and run the install command again. [INSTALL.md, Prerequisites](../INSTALL.md#prerequisites) lists the setups that work. |
| `install.sh: DatRail is already running from ...` | Another copy of DatRail is running. In the folder the message names, run `docker compose down` (its data is kept), then run the install command again. |
| `Your choice:` comes back with `Type one of the numbers or letters above.` | Type exactly one of the choices shown, such as `1` or `d`, and press **Return**. |
| Your agent isn't in the list | It has to run in a Docker container, and the container has to be running now. Check Step 3. If it isn't started yet, pick `c` and type its name. |
| Port 8000 is already in use | Another program uses that port. Install on another one: `curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh \| bash -s -- --port 18000`, then open http://127.0.0.1:18000 . |
| The install takes several minutes | It's downloading DatRail, about 540 MB. A slow connection takes longer. Later starts take seconds. |
| `install.sh: RailDash didn't become healthy in 3 minutes` | In `~/datrail`, run `docker compose logs raildash` to see why, then run the install command again. |
| The browser says it can't reach 127.0.0.1:8000 | DatRail isn't running, or Docker Desktop is closed. Open Docker Desktop, then in `~/datrail` run `docker compose ps`. If you installed on another port, use that one. |
| No interactions after a few minutes | Check that your agent is doing some work. In `~/datrail`, `docker compose logs railmon-collect` shows what the monitor attached to. |

Still stuck? More help is in [INSTALL.md, Troubleshooting](../INSTALL.md#troubleshooting), or ask on [GitHub](https://github.com/datrail/datrail-project/issues).
