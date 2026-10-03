#!/usr/bin/env python3
"""Check what the README's quick start promises, against a running stack.

With nobody touching the stack after `docker compose up -d`:

1. the demo agent's HTTPS calls reach RailDash as interactions (collect);
2. evidence bundles keep arriving as Agent Security Profiles (scan
   --interval), and they carry the agent's listening socket (listen);

then, driving RailDash's own HTTP routes the way the dashboard does:

3. a locked baseline makes the next ASP ALIGNED;
4. a port the agent opens afterwards makes a later ASP DRIFT_DETECTED, with
   observed_listeners among the changes.

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
    parser.add_argument("--open-port", required=True,
                        help="command that makes the demo agent open a new listening port")
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

    rows = wait_for("the demo agent's HTTPS calls arrive as interactions, unprompted",
                    demo_interactions, 300)
    print(f"      {len(rows)} demo interaction(s)")

    # The demo agent runs under Compose, so RailDash keys it by its Compose
    # project and service rather than the scanner's --agent-key fallback.
    def demo_asps() -> list[dict]:
        items = api(base, "/api/asps?limit=500")["items"]
        return [i for i in items
                if (i.get("agent_identity") or {}).get("kind") == "deployment_compose"
                and (i["agent_identity"].get("value") or {}).get("project") == args.project
                and (i["agent_identity"].get("value") or {}).get("service") == "demo-agent"]

    def listeners(asp_id: str) -> list[dict]:
        attribute = api(base, f"/api/asps/{asp_id}/bundle", token)["attributes"]["observed_listeners"]
        return (attribute.get("value") or []) if attribute.get("status") == "ANSWERED" else []

    def asp_with_demo_listener() -> str | None:
        for item in demo_asps():
            if any(l.get("port") == DEMO_PORT for l in listeners(item["asp_id"])):
                return item["asp_id"]
        return None

    wait_for("interval scans deliver more than one ASP, unprompted", lambda: len(demo_asps()) >= 2, 300)
    baseline = wait_for(f"an ASP records the agent listening on {DEMO_PORT}",
                        asp_with_demo_listener, 300)
    print(f"      listeners: {json.dumps(listeners(baseline))}")

    version = api(base, f"/api/asps/{baseline}/lock", token, {"version": f"ci-{time.time_ns()}"})
    api(base, f"/api/alignments/{version['alignment_version_id']}/switch", token, {})
    seen = {item["asp_id"] for item in demo_asps()}

    def next_state() -> dict | None:
        fresh = [i for i in demo_asps() if i["asp_id"] not in seen]
        if not fresh:
            return None
        seen.update(i["asp_id"] for i in fresh)
        return {i["asp_id"]: api(base, f"/api/asps/{i['asp_id']}/state") for i in fresh}

    states = wait_for("the next ASP after locking a baseline arrives", next_state, 120)
    unexpected = {a: s for a, s in states.items() if s.get("state") != "ALIGNED"}
    if unexpected:
        print(json.dumps(unexpected, indent=1))
        sys.exit("FAIL: an unchanged agent did not stay ALIGNED with its baseline")
    print("ok:   an unchanged agent stays ALIGNED")

    subprocess.run(shlex.split(args.open_port), check=True)

    def drifted() -> dict | None:
        for asp_id, state in (next_state() or {}).items():
            if state.get("state") == "DRIFT_DETECTED":
                return {"asp_id": asp_id, **state}
            if state.get("state") != "ALIGNED":
                print(json.dumps(state, indent=1))
                sys.exit(f"FAIL: {asp_id} is {state.get('state')}, expected ALIGNED or DRIFT_DETECTED")
        return None

    drift = wait_for("a port opened after the baseline shows up as drift", drifted, 180)
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
                      "demo_interactions": len(rows)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
