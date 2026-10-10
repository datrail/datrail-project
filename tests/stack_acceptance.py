#!/usr/bin/env python3
"""Check what the README's quick start promises, against a running stack.

With nobody touching the stack after `docker compose up -d`:

1. the agent's HTTPS calls reach RailDash as interactions (collect);
2. an evidence bundle arrives as an Agent Security Profile (scan
   --interval) and carries the agent's listening socket (listen) and the
   demo script it reads on every call (files);

then, driving RailDash's own HTTP routes the way the dashboard does:

3. switching to a locked baseline makes the agent's newest ASP ALIGNED. An
   unchanged agent's later scans re-send that same bundle, which RailDash
   keeps as one ASP (DR-157), so no new ASP is expected here, and any that
   arrives while the agent keeps doing its normal work must be ALIGNED: the
   evidence, the file list included, does not churn;
4. the Data Guardrail (DR-184 M4, the design's §6 step 4): adopting the
   unedited proposal from that baseline is Violated by the agent's own
   listener on 8443 and by its calls to 127.0.0.1, which its configuration
   doesn't declare; Allow this on both is Held once the next scan, capture
   and heartbeat arrive;
5. a port the agent opens afterwards makes the next interval scan deliver a
   new ASP, unprompted, that is DRIFT_DETECTED with observed_listeners among
   the changes, and is a `service_ports` violation. The command that opens
   it is a new process reading files of its own before it listens, so a
   scan in between may deliver an ASP that drifted on observed_file_access
   alone; any other new ASP must be ALIGNED;
6. then, in the agent: writing /data/report.zip is a `saved_files`
   violation; a POST with a body to a host outside both lists is an
   `uploads` and an `out_of_spec_calls` violation, and repeating it after
   Acknowledge re-opens the row; a GET without a body to a second such host
   is an `out_of_spec_calls` violation only. The requests go to the agent's
   own HTTPS server with another Host header, which is what RailDash judges
   them by, so no outside network is involved. The collector follows only
   the agent's own process session, not a `docker exec`, so they are seen
   on the server's side, as the agent's server reads them.

The agent is the demo agent (`--agent compose:demo-agent`, which RailDash
knows by its Compose project and service) or, for INSTALL.md's "Watch your
own agent", a container the user started (`--agent key:my-agent`, known by
the scanner's agent key). Either one serves the demo's HTTPS on 8443.

The local write token comes from RAILDASH_TOKEN_VALUE, never argv.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from typing import Any, Callable
from urllib.error import URLError
from urllib.request import Request, urlopen

DEMO_PORT = 8443
# The agent runs this script for every call it makes (the RailMon image's
# local demo), so railmon-files must report it read.
DEMO_SCRIPT = "/opt/railmon/tools/local-demo/demo_client.py"


def api(base: str, path: str, token: str | None = None, body: dict | None = None) -> Any:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-RailDash-Token"] = token
    data = json.dumps(body).encode() if body is not None else None
    request = Request(base + path, data=data, headers=headers,
                      method="POST" if body is not None else "GET")
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def wait_for(what: str, check: Callable[[], Any], timeout: float, every: float = 2.0) -> Any:
    deadline = time.monotonic() + timeout
    while True:
        try:
            result = check()
        except (URLError, OSError, KeyError, ValueError):
            result = None
        if result:
            print(f"ok:   {what}", flush=True)
            return result
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: {what} (gave up after {timeout:.0f}s)")
        time.sleep(every)


EXFIL_HOST = "exfil.example"
SECOND_HOST = "second.example"
# Run in the agent with `python3 -c AGENT_REQUEST <method> <host>`: one HTTPS
# request to the agent's own server on 8443 with that Host header, a JSON
# body for POST and none for GET. The collector doesn't capture this client
# (a `docker exec` isn't the agent's session); it captures the agent's own
# server reading the request, Host header and body included. The demo server
# answers a GET with 501, which is still a call. The certificate is the
# demo's throwaway one, hence no verification.
AGENT_REQUEST = """
import http.client, ssl, sys
method, host = sys.argv[1], sys.argv[2]
conn = http.client.HTTPSConnection("127.0.0.1", 8443, context=ssl._create_unverified_context(), timeout=10)
body = b'{"report": "quarterly numbers"}' if method == "POST" else None
headers = {"Host": host}
if body:
    headers["Content-Type"] = "application/json"
conn.request(method, "/upload", body=body, headers=headers)
print(method, host, conn.getresponse().status)
"""


class Guardrail:
    """The agent's Data Guardrail, through RailDash's token-gated routes."""

    def __init__(self, base: str, token: str, ours: Callable[[dict], bool]) -> None:
        self.base, self.token, self.ours = base, token, ours
        self.ref: str | None = None

    def _agent_ref(self) -> str:
        if self.ref is None:
            agents = api(self.base, "/api/guardrails", self.token)
            [agent] = [a for a in agents if self.ours(a.get("agent_identity") or {})]
            self.ref = agent["agent_ref"]
        return self.ref

    def detail(self) -> dict:
        return api(self.base, f"/api/guardrails/{self._agent_ref()}", self.token)

    def adopt(self, alignment_version_id: str) -> None:
        proposal = self.detail()["proposal"]
        if not proposal or not proposal.get("guardrail"):
            sys.exit(f"FAIL: no guardrail was proposed for the agent: {proposal}")
        print(f"      proposal: {json.dumps(proposal['guardrail']['rules'])}")
        print(f"      would be violations: "
              f"{[(v['rule'], v['item']) for v in proposal['would_be_violations']]}")
        adopted = api(self.base, f"/api/alignments/{alignment_version_id}/guardrail", self.token, {})
        print(f"ok:   adopted the unedited proposal as {adopted['guardrail']['version']}")

    def rows(self) -> dict[tuple[str, str], dict]:
        return {(r["rule"], r["item"]): r for r in self.detail()["rows"]}

    def row(self, rule: str, item: str) -> dict | None:
        return self.rows().get((rule, item))

    def wait_for(self, what: str, check: Callable[[], Any], timeout: float = 180) -> Any:
        try:
            return wait_for(what, check, timeout)
        except SystemExit:
            try:
                print(json.dumps(self.detail(), indent=1)[:20000])
            except (URLError, OSError, ValueError) as error:
                print(f"      (the guardrail's detail couldn't be read: {error})")
            raise

    def wait_for_rows(self, what: str, items: set[tuple[str, str]], *, exact: bool = False) -> None:
        def counting() -> bool:
            detail = self.detail()
            found = {(r["rule"], r["item"]) for r in detail["rows"] if r["counts"]}
            if exact and found - items:
                sys.exit(f"FAIL: {what}: unexpected rows {sorted(found - items)}")
            return detail["state"] == "violated" and items <= found
        self.wait_for(what, counting)

    def wait_for_state(self, state: str, what: str, timeout: float = 180) -> None:
        def reached() -> bool:
            detail = self.detail()
            print(f"      {detail['state']}: "
                  f"{ {rule: r['reason'] for rule, r in (detail['rules'] or {}).items() if r['reason']} }",
                  flush=True)
            return detail["state"] == state
        self.wait_for(what, reached, timeout)

    def allow(self, rule: str, item: str) -> None:
        row = self.row(rule, item)
        version = api(self.base, f"/api/guardrail-rows/{row['row_id']}/allow", self.token, {})
        print(f"ok:   Allow this on {rule} {item} made {version['guardrail']['version']}")

    def acknowledge(self, rule: str, item: str) -> None:
        row = self.row(rule, item)
        api(self.base, f"/api/guardrail-rows/{row['row_id']}/acknowledge", self.token, {})
        print(f"ok:   acknowledged {rule} {item}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True, help="RailDash base URL")
    parser.add_argument("--project", required=True, help="the compose project name")
    parser.add_argument("--agent", default="compose:demo-agent",
                        help="compose:<service> for a Compose service, key:<agent key> otherwise")
    parser.add_argument("--open-port", required=True,
                        help="command that makes the agent open a new listening port")
    parser.add_argument("--agent-exec", required=True,
                        help="command prefix that runs a command in the agent, e.g. 'docker exec my-agent'")
    parser.add_argument("--settle", type=float, default=30,
                        help="seconds the newest ASP must stay the newest before it is locked, "
                             "and that steady state is watched afterwards (a few scan intervals)")
    args = parser.parse_args()
    token = os.environ.get("RAILDASH_TOKEN_VALUE")
    if not token:
        sys.exit("set RAILDASH_TOKEN_VALUE to RailDash's local write token")
    base = args.url.rstrip("/")

    wait_for("RailDash is up", lambda: api(base, "/webhook/health"), 300)

    def demo_interactions() -> list[dict]:
        rows = api(base, "/api/interactions?limit=500")["items"]
        return [r for r in rows if r.get("path") in ("/v1/demo", "/v1/demo/other")
                and r.get("method") == "POST" and r.get("status_code") == 200]

    rows = wait_for("the agent's HTTPS calls arrive as interactions, unprompted",
                    demo_interactions, 300)
    print(f"      {len(rows)} demo interaction(s)")

    # A Compose service is keyed by its Compose project and service; any
    # other container by the scanner's --agent-key, which defaults to the
    # container's name.
    how, _, name = args.agent.partition(":")
    if how not in ("compose", "key") or not name:
        parser.error("--agent is compose:<service> or key:<agent key>")

    def ours(identity: dict) -> bool:
        kind, value = identity.get("kind"), identity.get("value")
        if how == "compose":
            return (kind == "deployment_compose" and isinstance(value, dict)
                    and value.get("project") == args.project and value.get("service") == name)
        return (kind == "local_agent_key" and value == name) or (
            kind == "local_agent_keys" and isinstance(value, list) and name in value)

    def demo_asps() -> list[dict]:
        items = api(base, "/api/asps?limit=500")["items"]
        return [i for i in items if ours(i.get("agent_identity") or {})]

    def listeners(asp_id: str) -> list[dict]:
        attribute = api(base, f"/api/asps/{asp_id}/bundle", token)["attributes"]["observed_listeners"]
        return (attribute.get("value") or []) if attribute.get("status") == "ANSWERED" else []

    def files(asp_id: str) -> list[dict]:
        attribute = api(base, f"/api/asps/{asp_id}/bundle", token)["attributes"]["observed_file_access"]
        return (attribute.get("value") or []) if attribute.get("status") == "ANSWERED" else []

    # The README's flow: lock the newest ASP. /api/asps lists the newest first.
    def newest_asp_with_demo_evidence() -> str | None:
        asps = demo_asps()
        if not asps:
            return None
        newest = asps[0]["asp_id"]
        if (any(l.get("port") == DEMO_PORT for l in listeners(newest))
                and any(f.get("path") == DEMO_SCRIPT and f.get("read") for f in files(newest))):
            return newest
        return None

    # The file list grows while the agent's first calls are still importing,
    # so a baseline locked halfway through one would drift on the rest. Lock
    # only an ASP that stayed the newest for --settle seconds: later scans
    # found nothing new.
    for _ in range(10):
        baseline = wait_for(f"the newest ASP records the agent listening on {DEMO_PORT} "
                            f"and reading {DEMO_SCRIPT}", newest_asp_with_demo_evidence, 300)
        time.sleep(args.settle)
        if demo_asps()[0]["asp_id"] == baseline:
            break
    else:
        sys.exit(f"FAIL: the agent's evidence was still changing after 10 waits of {args.settle:.0f}s")
    print(f"ok:   it stayed the newest ASP for {args.settle:.0f}s")
    print(f"      listeners: {json.dumps(listeners(baseline))}")
    opened = files(baseline)
    print(f"      files: {len(opened)} listed, "
          f"{sum(1 for f in opened if f.get('write'))} written, "
          f"{sum(1 for f in opened if f.get('exec'))} run")

    version = api(base, f"/api/asps/{baseline}/lock", token, {"version": f"ci-{time.time_ns()}"})
    api(base, f"/api/alignments/{version['alignment_version_id']}/switch", token, {})
    asps = demo_asps()
    seen = {item["asp_id"] for item in asps}

    # Switching compares the agent's newest ASP with the new baseline, so the
    # dashboard is ALIGNED at once, with no new scan needed. A scan may have
    # delivered a newer ASP since the lock; it is still the one to check.
    newest = asps[0]["asp_id"]
    state = api(base, f"/api/asps/{newest}/state")
    if state.get("state") != "ALIGNED":
        print(json.dumps(state, indent=1))
        sys.exit(f"FAIL: the agent's newest ASP {newest} is {state.get('state')} "
                 "right after its baseline was switched in, expected ALIGNED")
    print("ok:   the agent's newest ASP is ALIGNED once the baseline is switched in")

    def next_state() -> dict | None:
        fresh = [i for i in demo_asps() if i["asp_id"] not in seen]
        if not fresh:
            return None
        seen.update(i["asp_id"] for i in fresh)
        return {i["asp_id"]: api(base, f"/api/asps/{i['asp_id']}/state") for i in fresh}

    def changed(state: dict) -> list:
        return [c.get("name") for c in (state.get("drift") or {}).get("changes") or []]

    # Steady state: the agent keeps making its calls, and nothing it does
    # differs from the baseline, so nothing may drift.
    time.sleep(args.settle)
    for asp_id, state in (next_state() or {}).items():
        if state.get("state") != "ALIGNED":
            print(json.dumps(state, indent=1))
            sys.exit(f"FAIL: {asp_id} is {state.get('state')} ({changed(state)}) while the agent "
                     "only did its normal work, expected ALIGNED")
    print(f"ok:   nothing drifted in {args.settle:.0f}s of the agent's normal work")

    # ---- 4. the Data Guardrail ---------------------------------------------
    guard = Guardrail(base, token, ours)
    guard.adopt(version["alignment_version_id"])
    guard.wait_for_rows(
        "adopting the unedited proposal is Violated by the agent's own listener and its "
        "undeclared calls to 127.0.0.1",
        {("service_ports", f"tcp/127.0.0.1/{DEMO_PORT}"), ("out_of_spec_calls", "127.0.0.1")},
        exact=True,
    )
    for rule, item in (("service_ports", f"tcp/127.0.0.1/{DEMO_PORT}"),
                       ("out_of_spec_calls", "127.0.0.1")):
        guard.allow(rule, item)
    guard.wait_for_state("held", "with both allowed, the next scan, capture and heartbeat are Held",
                         timeout=240)

    subprocess.run(shlex.split(args.open_port), check=True)

    def drifted() -> dict | None:
        for asp_id, state in (next_state() or {}).items():
            if state.get("state") == "DRIFT_DETECTED" and changed(state) == ["observed_file_access"]:
                print(f"      {asp_id} drifted on observed_file_access only: the new process "
                      "read its files before it listened")
                continue
            if state.get("state") == "DRIFT_DETECTED":
                return {"asp_id": asp_id, **state}
            if state.get("state") != "ALIGNED":
                print(json.dumps(state, indent=1))
                sys.exit(f"FAIL: {asp_id} is {state.get('state')}, expected ALIGNED or DRIFT_DETECTED")
        return None

    drift = wait_for("the next interval scan delivers the opened port as drift, unprompted",
                     drifted, 180)
    names = changed(drift)
    print(f"      changed: {names}")
    if "observed_listeners" not in names:
        print(json.dumps(drift, indent=1))
        sys.exit("FAIL: observed_listeners is not among the drift changes")
    print("ok:   observed_listeners is among the changes")
    guard.wait_for_rows("(a) the opened port is a service_ports violation",
                        {("service_ports", "tcp/127.0.0.1/9000")})

    agent = shlex.split(args.agent_exec)
    subprocess.run([*agent, "sh", "-c", "mkdir -p /data && echo report > /data/report.zip"], check=True)
    guard.wait_for_rows("(b) writing /data/report.zip is a saved_files violation",
                        {("saved_files", "/data/report.zip")})

    send = lambda method, host: subprocess.run(  # noqa: E731
        [*agent, "python3", "-c", AGENT_REQUEST, method, host], check=True)
    send("POST", EXFIL_HOST)
    guard.wait_for_rows("(c) a POST with a body to an unlisted host is an uploads and an "
                        "out_of_spec_calls violation",
                        {("uploads", EXFIL_HOST), ("out_of_spec_calls", EXFIL_HOST)})
    guard.acknowledge("uploads", EXFIL_HOST)
    if guard.row("uploads", EXFIL_HOST)["counts"]:
        sys.exit("FAIL: an acknowledged row still counts")
    send("POST", EXFIL_HOST)
    guard.wait_for(
        "(d) the same POST after Acknowledge re-opens the row",
        lambda: (row := guard.row("uploads", EXFIL_HOST)) and row["counts"] and row["count"] >= 2,
    )
    send("GET", SECOND_HOST)
    guard.wait_for_rows("(e) a GET without a body to a second unlisted host is an "
                        "out_of_spec_calls violation", {("out_of_spec_calls", SECOND_HOST)})
    if guard.row("uploads", SECOND_HOST) is not None:
        sys.exit(f"FAIL: a GET without a body to {SECOND_HOST} was judged an upload")
    print("ok:   ... and not an upload")

    with urlopen(base + "/", timeout=30) as response:
        page = response.read().decode("utf-8", "replace")
    if "Agent Security Profile" not in page:
        sys.exit("FAIL: the dashboard page has no Agent Security Profile panel")
    print("ok:   the dashboard serves its Agent Security Profile panel")
    if "Data Guardrail" not in page:
        sys.exit("FAIL: the dashboard page has no Data Guardrail panel")
    print("ok:   ... and its Data Guardrail panel")
    print(json.dumps({"result": "PASS", "baseline": baseline, "drifted": drift["asp_id"],
                      "demo_interactions": len(rows), "baseline_files": len(opened)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
