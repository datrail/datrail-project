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
   keeps as one ASP (DR-157), so no new ASP is expected here;
4. a port the agent opens afterwards makes the next interval scan deliver a
   new ASP, unprompted, that is DRIFT_DETECTED with observed_listeners among
   the changes. Any other new ASP in between must still be ALIGNED.

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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True, help="RailDash base URL")
    parser.add_argument("--project", required=True, help="the compose project name")
    parser.add_argument("--agent", default="compose:demo-agent",
                        help="compose:<service> for a Compose service, key:<agent key> otherwise")
    parser.add_argument("--open-port", required=True,
                        help="command that makes the agent open a new listening port")
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

    baseline = wait_for(f"the newest ASP records the agent listening on {DEMO_PORT} "
                        f"and reading {DEMO_SCRIPT}", newest_asp_with_demo_evidence, 300)
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

    subprocess.run(shlex.split(args.open_port), check=True)

    def drifted() -> dict | None:
        for asp_id, state in (next_state() or {}).items():
            if state.get("state") == "DRIFT_DETECTED":
                return {"asp_id": asp_id, **state}
            if state.get("state") != "ALIGNED":
                print(json.dumps(state, indent=1))
                sys.exit(f"FAIL: {asp_id} is {state.get('state')}, expected ALIGNED or DRIFT_DETECTED")
        return None

    drift = wait_for("the next interval scan delivers the opened port as drift, unprompted",
                     drifted, 180)
    names = [c.get("name") for c in (drift.get("drift") or {}).get("changes") or []]
    print(f"      changed: {names}")
    if "observed_listeners" not in names:
        print(json.dumps(drift, indent=1))
        sys.exit("FAIL: observed_listeners is not among the drift changes")
    print("ok:   observed_listeners is among the changes")

    with urlopen(base + "/", timeout=30) as response:
        page = response.read().decode("utf-8", "replace")
    if "Agent Security Profile" not in page:
        sys.exit("FAIL: the dashboard page has no Agent Security Profile panel")
    print("ok:   the dashboard serves its Agent Security Profile panel")
    print(json.dumps({"result": "PASS", "baseline": baseline, "drifted": drift["asp_id"],
                      "demo_interactions": len(rows), "baseline_files": len(opened)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
