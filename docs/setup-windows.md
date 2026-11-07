# Install DatRail on Windows

DatRail is an open-source tool for people who want to keep an eye on what their own AI agent does with their data, on their own computer. This guide takes you from nothing to DatRail watching an agent on your Windows PC, one step at a time. It shows what you should see after each step, so you can tell it worked before you move on.

It takes about 20 minutes the first time, most of it installing WSL and Docker Desktop. Using a Mac instead? See [Install DatRail on a Mac](setup-mac.md).

## What you get

DatRail watches what an AI agent does: the services it calls, the files it opens and the ports it listens on. It learns the agent's normal behavior and tells you when the agent does something new. You see it all in a dashboard in your web browser.

DatRail has two parts, and both run on your PC:

- **RailMon**, the monitor, which watches the agent
- **RailDash**, the dashboard, which you open in your browser at http://127.0.0.1:8000

DatRail runs on Linux. On Windows, it runs inside **WSL** (Windows Subsystem for Linux), a part of Windows that runs Linux alongside it. You install WSL in Step 1, and you never have to leave Windows to use DatRail: the dashboard opens in your usual browser.

> [!IMPORTANT]
> **Your agent needs to run in a Docker container.** DatRail is built for agents that already run in a sandbox, such as a Docker container. It can't see an agent running directly on your PC, in Windows or in WSL. DatRail watches an agent inside its sandbox. It doesn't sandbox the agent for you. No agent in a container yet? You can try DatRail with its demo agent first.

### Words you'll see

| Word | What it means |
| --- | --- |
| **Container** | A sealed-off space where a program runs, separate from the rest of your PC. Docker Desktop runs containers. |
| **WSL and Ubuntu** | WSL lets Windows run Linux. Ubuntu is the version of Linux this guide installs in it. |
| **Profile (ASP)** | DatRail's record of what the agent did: the ports it listened on and the files it opened. RailDash calls it an Agent Security Profile, or ASP. |
| **Baseline** | A profile you choose as "this is normal for my agent". |
| **Drift** | Something the agent did that its baseline doesn't cover. |
| **Data Guardrail** | Rules for what the agent may do with data: uploads, saved files, ports and calls. You approve every rule. |

The [glossary](glossary.md) explains every term in more detail.

## Before you start

You need:

- **An up-to-date Windows 11 or Windows 10.** Docker Desktop's [system requirements](https://docs.docker.com/desktop/setup/install/windows-install/) list the versions it supports. To check yours: press **Windows key + R**, type `winver`, and press **Enter**.
- **A PC with an Intel or AMD processor.** To check: open **Settings**, then **System**, then **About**, and look at **Processor**. PCs with an ARM processor (such as Snapdragon) haven't been tested.
- **Virtualization turned on.** WSL needs it, and most PCs have it on already. To check: open **Task Manager** (Ctrl + Shift + Esc), click **Performance**, then **CPU**, and look for **Virtualization: Enabled**. If it says Disabled, see [If something goes wrong](#if-something-goes-wrong).
- **Administrator rights on the PC**, for the installs.
- **About 10 GB of free disk space**: WSL, Docker Desktop and DatRail together.
- **An internet connection**, for the downloads.

## Step 1: Install WSL and Ubuntu

If you already have WSL with Ubuntu, skip to "Check that it's WSL version 2" below.

1. **Open PowerShell as administrator.** Open the Start menu and type **PowerShell**. Right-click **Windows PowerShell** and choose **Run as administrator**. When Windows asks whether to allow this app to make changes, click **Yes**.
2. **Install WSL and Ubuntu.** Copy this command, right-click in the PowerShell window to paste it, and press **Enter**:

   ```powershell
   wsl --install -d Ubuntu
   ```

   It downloads and installs WSL and Ubuntu. This takes a few minutes.
3. **Restart the PC** if it asks you to.
4. **Set up your Linux user.** After the install (or after the restart), an **Ubuntu** window opens and finishes setting up. If it doesn't open, open **Ubuntu** from the Start menu. It asks for:
   - **A user name**: lowercase letters and no spaces, such as `alex`. It doesn't have to match your Windows name.
   - **A password**, typed twice. Nothing appears on screen while you type it: that's normal. Remember it, because Ubuntu asks for it now and then.

   When it's done, the window shows a line ending in `$`, such as `alex@DESKTOP-1234:~$`. This is where you type commands.

**Check that it's WSL version 2.** In PowerShell, run:

```powershell
wsl -l -v
```

You should see Ubuntu with `2` in the `VERSION` column:

```text
  NAME      STATE           VERSION
* Ubuntu    Running         2
```

If it says `1`, see [If something goes wrong](#if-something-goes-wrong).

## Step 2: Install Docker Desktop and connect it to Ubuntu

DatRail runs inside Docker Desktop, a free app that runs containers on your PC. If you already have it, skip to step 6 below to check its settings.

1. Go to https://www.docker.com/products/docker-desktop/ and click **Download Docker Desktop**. Choose **Windows - AMD64** (it's the one for both Intel and AMD processors).
2. Open the downloaded file, `Docker Desktop Installer.exe`. Click **Yes** if Windows asks whether to allow it to make changes.
3. On the configuration page, keep **Use WSL 2 instead of Hyper-V** ticked, and click **OK**. It takes a few minutes.
4. When it's done, click **Close**. If it asks you to sign out or restart, do so.
5. Open **Docker Desktop** from the Start menu. Accept its service agreement. It may ask you to sign in to a Docker account or answer a short survey: neither is needed for DatRail, and you can choose **Skip** for both.
6. **Connect it to Ubuntu.** Click the gear icon at the top right to open **Settings**, then:
   - Under **General**, check that **Use the WSL 2 based engine** is ticked.
   - Under **Resources**, then **WSL integration**, turn on the switch next to **Ubuntu**.
7. Click **Apply & restart**.

**Check that it's running.** The Docker whale icon appears in the taskbar, near the clock (you may need to click the **^** arrow to see it). In the Docker Desktop window, the bottom left corner should say **Engine running**, in green.

Docker Desktop has to be running whenever you use DatRail. If you quit it, DatRail stops too, and it starts again when you open Docker Desktop.

## Step 3: Open Ubuntu

You install and manage DatRail from the Ubuntu window, not from PowerShell.

1. Open the Start menu, type **Ubuntu**, and press **Enter**. A window opens with a line ending in `$`.

**How to run a command from this guide:** copy it (each command box has a copy button on its top right), right-click in the Ubuntu window to paste it, then press **Enter**. From here on, every command in this guide runs in the Ubuntu window.

**Check that Ubuntu can reach Docker.** Run:

```bash
docker version
```

You should see two sections, **Client** and **Server**. If it says the command `docker` could not be found in this WSL 2 distro, Docker Desktop isn't running, or its WSL integration is off for Ubuntu (Step 2, step 6). Right after Docker Desktop starts, wait a few seconds and try again.

## Step 4: Find your agent's container (skip if you're trying the demo agent)

The installer lists the containers running now, and you pick your agent from that list. So, before you start the installer:

1. Make sure your agent's container is running.
2. Find its name. In Docker Desktop, click **Containers** on the left: the **Name** column lists each container. Or, in Ubuntu, run:

   ```bash
   docker ps --format '{{.Names}}'
   ```

   It prints one name per line, such as `my-agent`.

If your agent's container isn't running right now, you can still type its name in the installer (option `c`), and DatRail attaches to it when it starts.

## Step 5: Install DatRail

In Ubuntu, run:

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash
```

This downloads DatRail's installer and runs it. It adds a `datrail` folder to your Ubuntu home folder and runs DatRail's containers in Docker Desktop.

### 5.1 It checks your PC

First it prints:

```text
==> Checking that this machine can run DatRail
Docker x86_64, Docker Desktop: OK
Note: with Docker Desktop, DatRail sees only agents running in Docker containers, not one running directly on this computer.

==> Getting docker-compose.yml into /home/alex/datrail
```

If you see a message starting with `install.sh:` instead, the check found a problem: see [If something goes wrong](#if-something-goes-wrong).

When you run the install command again later, to switch agents or update DatRail, it may also print `Updating the docker-compose.yml already there (the old one is kept as docker-compose.yml.old).` That's expected: your data is kept.

### 5.2 It asks which agent to watch

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

Your list shows your own containers in place of `my-agent`. If none are running, it says `No container is running now, apart from DatRail's own.` instead, followed by the same letters. Type one choice and press **Enter**:

| Type | To |
| --- | --- |
| A number, such as `1` | Watch that container, your agent. It keeps running: there's no need to restart it. |
| `d` | Try DatRail with its demo agent: a small agent that comes with DatRail and calls itself every 30 seconds. This guide's later steps show what it does. |
| `c` | Watch a container that isn't running yet. Type its name when asked. DatRail attaches to it when it starts. |
| `n` | Stop here if your agent doesn't run in a container. The installer explains what to do and ends without starting DatRail. |
| `o` | Not for Windows: OpenShell sandboxes need a Linux computer. |

You can watch one agent at a time. To switch later, run the install command again.

### 5.3 It downloads and starts DatRail

```text
==> Writing the settings to /home/alex/datrail/.env
Watching my-agent.

==> Starting DatRail (the first run downloads two images, about 540 MB)
```

The download takes about a minute on a normal connection, and the window shows its progress. Then:

```text
Waiting for RailDash...
```

and a short table of DatRail's parts, each one `Up`. If you picked your own agent, it also tells you that the agent doesn't need a restart. A file the agent opened before DatRail started, such as its configuration, shows up once the agent opens that file again.

### 5.4 It's running

The installer ends with:

```text
==> DatRail is running
Open http://127.0.0.1:8000 in a browser on this computer.
```

DatRail is installed. Its files are in a folder called `datrail` in your Ubuntu home folder. You don't need to open or change anything in there, but you can see it from File Explorer: type `\\wsl$\Ubuntu\home` in the address bar, then open your Linux user's folder.

## Step 6: Open the dashboard

In your usual Windows web browser, go to http://127.0.0.1:8000 . This page lives on your PC, so it only works on this computer.

Within a few minutes you should see two things:

- **Interactions**: every call the agent makes, with where it went, the method, the path and the result. The demo agent's calls go to itself, at `127.0.0.1:8443`, so each one shows twice, once from each side.
- **Agent Security Profile alignment**: the agent's profiles. The first one appears within a few minutes, with the ports the agent listens on and the files it opened. Click **Inspect evidence** on a profile to see them.

RailMon checks the agent every minute. A new profile appears only when it finds something new, so an agent that's sitting idle shows little. Let your agent do its normal work.

## Step 7: Lock a baseline

A baseline tells DatRail what's normal for your agent.

1. **Let the agent do its normal work for a while**, so its profile covers what it usually does. With the demo agent, wait until there are two profiles under **Agent Security Profile alignment**. The second arrives about a minute after the first, with the files the agent opened.
2. **On the newest profile, click Lock this as your alignment baseline.** The status changes to **ALIGNED, v1.0 (active)**.

From now on, DatRail compares everything the agent does with this baseline.

**See drift with the demo agent.** Make it open a port it didn't have before. In Ubuntu:

```bash
docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1
```

Within a minute, RailDash shows **DRIFT DETECTED**. Under the drift, `observed_listeners` lists the new port, 9000. That's DatRail noticing something new.

With your own agent, drift appears the same way when it does something its baseline doesn't cover. You can accept the new behavior as a new baseline, or switch back to an earlier one.

## Step 8: Adopt a Data Guardrail

Once a baseline is locked, the **Data Guardrail** panel proposes rules for the agent based on it: what the agent already did is allowed. It shows every rule before you approve it, and lists what would break the rules today.

1. **Read the proposal**, then click **Adopt**.
2. **Within a minute, anything outside the rules shows as a row.** With the demo agent there are two, both under **Service ports**: its own port 8443, and port 9000, still open from the drift step.
3. **Decide on each row:**
   - **Allow this** adds it to the rules, as a new version of the guardrail. Use it for something the agent is meant to do. With the demo agent, click **Allow all 2** under Service ports to allow both ports at once.
   - **Acknowledge** clears the row for now. It comes back if the same thing happens again.
4. **After the next check, a minute or two later, the agent reads Held**: it's inside its rules.

**See a broken rule with the demo agent.** Make it save a file its rules don't allow. In Ubuntu:

```bash
docker exec datrail-demo-agent sh -c 'mkdir -p /data && echo report > /data/report.zip'
```

Within a minute or two the agent reads **Violated**, with `/data/report.zip` under **Saved files**.

From the same panel you can edit the rules, switch to an earlier version, or turn the guardrail off. [What you see in RailDash](../README.md#what-you-see-in-raildash) goes further: uploads, calls to unknown hosts, and what each tool may do with data.

## Using DatRail day to day

DatRail keeps running in the background and starts again whenever Docker Desktop does. To manage it, open Ubuntu and go to its folder first:

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
| Watch a different agent | Run the install command from Step 5 again |
| Update to the latest version | Run the install command from Step 5 again. It keeps your data. |
| Remove it completely | `docker compose down -v --rmi all`, then `cd ~ && rm -rf ~/datrail` |

Removing it deletes DatRail's data and its downloads. It never touches your agent or its container. Docker Desktop and WSL stay installed. Remove them from **Settings**, then **Apps**, if you no longer need them.

## Other ways to install

- **Let your AI agent install it.** Tell your agent: *"Read https://raw.githubusercontent.com/datrail/datrail-project/master/docs/agent-install.md and install DatRail for me."* That page has it ask you before anything that needs full control of your PC, and it never changes your agent.
- **Every setting and option,** including building DatRail from source, is in [INSTALL.md](../INSTALL.md).

## If something goes wrong

| What you see | What to do |
| --- | --- |
| Task Manager shows **Virtualization: Disabled**, or `wsl --install` fails with error `0x80370102` | Virtualization is off in your PC's firmware (BIOS or UEFI). Turn it on there; its name depends on the maker, often **Intel VT-x**, **Intel Virtualization Technology** or **AMD-V / SVM Mode**. Your PC maker's support site shows how. |
| `wsl -l -v` shows `1` next to Ubuntu | In PowerShell as administrator, run `wsl --set-version Ubuntu 2`, then check again. |
| The command `docker` could not be found in this WSL 2 distro | Docker Desktop isn't running, or its WSL integration is off for Ubuntu (Step 2, step 6). Right after Docker Desktop starts, wait a few seconds and try again. |
| `install.sh: Docker isn't installed` | On Windows this usually means Docker Desktop is closed, or its WSL integration is off for Ubuntu: closing Docker Desktop removes the `docker` command from Ubuntu. Open Docker Desktop, wait until it says **Engine running**, check its WSL integration (Step 2, step 6), then run the install command again. If Docker Desktop isn't installed yet, install it first (Step 2). |
| `install.sh: Docker is installed but not running` | Open Docker Desktop, wait until it says **Engine running**, then run the install command again. |
| `install.sh: Docker can't run a privileged container with BTF` | Update Docker Desktop to its latest version (whale icon in the taskbar, **Check for updates**), check the settings in Step 2, and run the install command again. [INSTALL.md, Prerequisites](../INSTALL.md#prerequisites) lists the setups that work. |
| `install.sh: DatRail is already running from ...` | Another copy of DatRail is running. In the folder the message names, run `docker compose down` (its data is kept), then run the install command again. |
| `Your choice:` comes back with `Type one of the numbers or letters above.` | Type exactly one of the choices shown, such as `1` or `d`, and press **Enter**. |
| Your agent isn't in the list | It has to run in a Docker container, and the container has to be running now. Check Step 4. If it isn't started yet, pick `c` and type its name. |
| `install.sh: the stack didn't start; ...` | Look at the lines just above it. If they mention port 8000 (`port is already allocated` or `address already in use`), another program uses that port: install on another one with `curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh \| bash -s -- --port 18000`, then open http://127.0.0.1:18000 . Otherwise, in `~/datrail`, run `docker compose logs` to see why, then run the install command again. |
| The install takes several minutes | It's downloading DatRail, about 540 MB. A slow connection takes longer. Later starts take seconds. |
| `install.sh: RailDash didn't become healthy in 3 minutes` | In `~/datrail`, run `docker compose logs raildash` to see why, then run the install command again. |
| The browser says it can't reach 127.0.0.1:8000 | DatRail isn't running, or Docker Desktop is closed. Open Docker Desktop, then in `~/datrail` run `docker compose ps`. If you installed on another port, use that one. |
| No interactions after a few minutes | Check that your agent is doing some work. In `~/datrail`, `docker compose logs railmon-collect` shows what the monitor attached to. |

Still stuck? More help is in [INSTALL.md, Troubleshooting](../INSTALL.md#troubleshooting), or ask on [GitHub](https://github.com/datrail/datrail-project/issues).
