# Installing DatRail: instructions for an AI agent

You are an AI agent, and a person has asked you to install DatRail so that it
watches an agent they already run. Follow this page step by step.
It is written so that the person doesn't have to run anything themselves.

A person can hand this page to their agent with one sentence:

> Read https://raw.githubusercontent.com/datrail/datrail-project/master/docs/agent-install.md and install DatRail for me.

## What DatRail is, in two sentences, for the person

DatRail watches an AI agent while it runs: the services it calls, the files it
writes and the ports it opens. It shows them on a dashboard at
`http://127.0.0.1:8000` on this computer, where the person locks what is
normal and is shown anything new. Nothing leaves the computer.

## Rules while you do this

- **Ask the person before step 1.** DatRail runs containers with full
  control of this computer: four of its containers are privileged or reach
  Docker itself, because its eBPF probes and scanner need that, and step 1's
  check already starts one. Say so in one sentence and wait for a yes.
- **Never use `sudo`, and never change Docker's settings** without the person
  saying yes to that exact command.
- **Don't stop, restart or change the person's agent.** DatRail doesn't need
  it. If the agent has to move into a container (step 2), tell the person and
  stop there; don't do it for them.
- **If you are the agent to be watched**, that's fine: DatRail runs beside you
  and doesn't change what you do. But see step 2 for where you run.
- Report each step's result in plain words, not command output.

## On Windows: run every command in WSL

DatRail runs in WSL2 (the Linux inside Windows) with Docker Desktop. Unless
your shell is bash inside WSL, run each command on this page through WSL, as
it is written here, inside double quotes. That includes PowerShell, cmd, and
Git Bash or another MSYS shell: there `docker` is Windows' own, which can't
run DatRail's checks, and `~` is the Windows home.

```powershell
wsl -e bash -lc "curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash -s -- --check"
```

`-e` hands the command to bash unchanged; none of the commands here contain a
`$` or a double quote, so the Windows shell passes them as they are. Each
`wsl` call starts afresh, so a `cd` doesn't carry over to the next one. If
your shell is already bash inside WSL, run them directly.

- `wsl` isn't found, or says there is no installed distribution: WSL2 isn't
  set up. That needs administrator rights and a restart, so it is the
  person's step: stop and point them to steps 1 and 2 of
  https://github.com/datrail/datrail-project/blob/master/docs/setup-windows.md,
  then offer to continue.
- `~/datrail` below is in WSL's home directory, not the Windows one. The
  dashboard still opens in the person's Windows browser at
  `http://127.0.0.1:8000`.

## Step 1: Check the computer

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash -s -- --check
```

- It ends with `This machine can run DatRail.`: go on to step 2.
- `Docker isn't installed`: tell the person they need Docker. On a Mac or
  Windows that is Docker Desktop (https://www.docker.com/products/docker-desktop/);
  on Linux, Docker Engine. Installing it needs them, so stop here and offer to
  continue once it's installed.
  On Windows with Docker Desktop already installed, the message means
  Docker Desktop isn't running (WSL loses the `docker` command while it is
  closed) or its WSL integration is off for this distro: ask the person to
  start it, or turn the integration on (Docker Desktop, Settings, Resources,
  WSL integration), then run the check again.
- `not running`: ask them to start Docker Desktop, wait until it says it's
  running, then run the check again.
- Anything else: tell them the message as it is, and point them to
  https://github.com/datrail/datrail-project/blob/master/INSTALL.md#prerequisites.

## Step 2: Find the agent to watch

DatRail watches an agent that runs in a Docker container (or in an NVIDIA
OpenShell sandbox on Linux). List what is running:

```bash
docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}'
```

- **One of these is the person's agent**: note its name (first column). If
  you aren't sure which, ask the person, showing them the list.
- **The agent is not in a container** (it runs directly on the Mac or PC,
  for example as an app or a terminal program): DatRail can't fully watch
  it there, and on a Mac or with Docker Desktop it can't see it at all. Tell
  the person that the agent has to run in a Docker container for DatRail to
  watch it, and stop. Offer the demo (`--demo` in step 3) to try DatRail
  first.
- **The person only wants to try DatRail**: use `--demo` in step 3.

## Step 3: Install

With the agent's container name in place of `NAME`:

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash -s -- --agent NAME --yes
```

For an agent in an OpenShell sandbox, `--agent openshell:SANDBOX` with the
sandbox's name. To try the demo instead: `--demo --yes` in place of
`--agent NAME --yes`.

It downloads about 540 MB the first time and takes a few minutes. It puts
its files in `~/datrail`, starts everything, and waits until the dashboard
answers. It ends with `DatRail is running`. If it stops with a message
instead, tell the person the message as it is.

## Step 4: Check it works, and tell the person

```bash
cd ~/datrail && docker compose ps
```

Every service should be `Up`, and `raildash` `healthy`. Then tell the person:

1. Open **http://127.0.0.1:8000** in a browser on this computer.
2. Within a few minutes the dashboard lists the agent's calls, and an
   **Agent Security Profile** for it appears (RailMon scans every minute).
   An agent that is idle shows little; it appears as the agent works.
3. Once the agent has done its normal work for a while, they click to lock
   that profile as the agent's **baseline**. Anything the agent does later
   that the baseline doesn't cover is shown as **drift**.
4. They can then adopt the proposed **Data Guardrail**, which checks every
   upload, saved file, port and call against what they approved.

No restart is needed, of the agent or of anything else. DatRail keeps
running, and starts again with Docker.

## Later

| The person asks | Run |
| --- | --- |
| Is it running? | `cd ~/datrail && docker compose ps` |
| Watch another agent | the step 3 command with the other `NAME` |
| Stop it (keep the data) | `cd ~/datrail && docker compose down` |
| Remove it and its data | `cd ~/datrail && docker compose down -v` |

[INSTALL.md](../INSTALL.md) has every setting and what to do when something
looks wrong.
