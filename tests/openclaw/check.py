"""What the stack makes of a real OpenClaw agent (tests/openclaw/acceptance.sh).

1. Its model calls arrive as interactions, streamed replies included: a
   reply carrying the stub's `stubreply-tool-` marker, paired with its
   request, whose tool call RailDash counts (railmon#70).
2. A baseline locked once the agent's writes show stays ALIGNED while the
   agent keeps taking turns, each writing a file of a new uuid name
   (railmon#97: a real agent's files drifted after every turn).
3. The unedited guardrail proposal, adopted on that baseline, is Violated
   only by the model's undeclared host and, for OpenClaw's gateway, the
   port it listens on (`--listener`); the OpenClaw services the gateway
   calls itself at start (`--call`) are among its would-be violations
   too. With those allowed it reads Held and stays Held through the same
   turns, each writing SQLite temp files and a fresh mkdtemp directory.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from stack_acceptance import Guardrail, api, wait_for  # noqa: E402

CHAT_PATH = "/v1/chat/completions"
MODEL_HOST = "my-model"
# OpenClaw's write tool writes the note to `.fs-safe-<uuid>.tmp` beside it
# and renames that over notes/turn.txt, so each turn writes a file of a new
# name: what railmon#97 drifted on.
NOTES = "/home/node/work/notes/"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True, help="RailDash base URL")
    parser.add_argument("--agent", required=True, help="the agent key RailMon names the agent by")
    parser.add_argument("--settle", type=float, default=30,
                        help="seconds of further scans between the agent's writes showing and "
                             "the lock")
    parser.add_argument("--watch", type=float, default=120,
                        help="seconds of further turns that must leave the baseline and guardrail be")
    parser.add_argument("--listener", action="append", default=[],
                        help="a listener the agent opens itself, as protocol/addr/port "
                             "(OpenClaw's gateway: tcp/0.0.0.0/18789); repeatable")
    parser.add_argument("--call", action="append", default=[],
                        help="a host the agent calls itself, beside the model (OpenClaw's "
                             "gateway: its update check, model catalog and plugin catalog); "
                             "repeatable")
    args = parser.parse_args()
    token = os.environ.get("RAILDASH_TOKEN_VALUE")
    if not token:
        sys.exit("set RAILDASH_TOKEN_VALUE to RailDash's local write token")
    base = args.url.rstrip("/")
    wait_for("RailDash is up", lambda: api(base, "/webhook/health"), 300)

    # ---- 1. the model calls, streamed replies included --------------------
    def chat_calls() -> list[dict]:
        rows = api(base, "/api/interactions?limit=500")["items"]
        return [r for r in rows if r.get("path") == CHAT_PATH and r.get("method") == "POST"]

    def marked(kind: str) -> list[dict]:
        found = []
        for row in chat_calls()[:40]:
            raw = json.dumps(api(base, f"/api/interactions/{row['id']}").get("raw"))
            if f"stubreply-{kind}-" in raw:
                found.append(row)
        return found

    calls = wait_for(f"OpenClaw's POSTs to {CHAT_PATH} arrive as interactions", chat_calls, 300)
    print(f"      {len(calls)} so far; hosts {sorted({str(c.get('host')) for c in calls})}, "
          f"statuses {sorted({str(c.get('status_code')) for c in calls})}, "
          f"agent keys {sorted({str(c.get('agent_key')) for c in calls})}")
    tool_replies = wait_for("a streamed reply asking for a tool call is captured with its request",
                            lambda: marked("tool"), 180)
    counted = [r for r in tool_replies if (r.get("tool_calls") or 0) >= 1]
    if not counted:
        print(json.dumps(tool_replies[:2], indent=1))
        sys.exit("FAIL: RailDash counts no tool call in any captured tool-call reply")
    print(f"ok:   RailDash counts the tool call in {len(counted)} of {len(tool_replies)} such replies")
    wait_for("the streamed answer to the tool's result is captured too", lambda: marked("text"), 180)

    # ---- 2. a baseline that holds through the agent's turns ---------------
    def ours(identity: dict) -> bool:
        kind, value = identity.get("kind"), identity.get("value")
        return (kind == "local_agent_key" and value == args.agent) or (
            kind == "local_agent_keys" and isinstance(value, list) and args.agent in value)

    def agent_asps() -> list[dict]:
        return [i for i in api(base, "/api/asps?limit=500")["items"]
                if ours(i.get("agent_identity") or {})]

    def file_access(asp_id: str) -> dict:
        return api(base, f"/api/asps/{asp_id}/bundle", token)["attributes"]["observed_file_access"]

    def newest_with_note() -> str | None:
        asps = agent_asps()
        if not asps:
            return None
        newest = asps[0]["asp_id"]
        listed = file_access(newest).get("value") or []
        return newest if any(f.get("path", "").startswith(NOTES) and f.get("write")
                             for f in listed) else None

    # Unlike the demo agent's, this agent's evidence never settles: every
    # turn writes a file of a new name. So the newest ASP is locked once it
    # has the agent's writes and a few more scans went by, and every ASP
    # after it must still read ALIGNED.
    wait_for(f"the newest ASP records the agent writing under {NOTES}", newest_with_note, 300)
    time.sleep(args.settle)
    baseline = wait_for(f"after {args.settle:.0f}s more, the newest ASP still does", newest_with_note, 60)
    files = file_access(baseline)
    listed = files.get("value") or []
    print(f"      observed_file_access {files.get('status')}: {len(listed)} listed, "
          f"{sum(1 for f in listed if f.get('write'))} written; note: {files.get('note')!r}")
    print(f"      written under {NOTES}: "
          f"{sorted(f['path'] for f in listed if f.get('path', '').startswith(NOTES) and f.get('write'))}")

    version = api(base, f"/api/asps/{baseline}/lock", token, {"version": f"ci-{time.time_ns()}"})
    api(base, f"/api/alignments/{version['alignment_version_id']}/switch", token, {})
    seen = {i["asp_id"] for i in agent_asps()}
    state = api(base, f"/api/asps/{agent_asps()[0]['asp_id']}/state")
    if state.get("state") != "ALIGNED":
        print(json.dumps(state, indent=1))
        sys.exit(f"FAIL: the newest ASP is {state.get('state')} right after the switch, expected ALIGNED")
    print("ok:   locked and switched in; the newest ASP is ALIGNED")

    # ---- 3. the guardrail proposal, adopted -------------------------------
    # The model's host is in no declaration RailMon reads (the agent's
    # config names it), so its calls are out of spec until the user allows
    # them, the one click the proposal lists. A gateway's own port is
    # allowed by no proposal outside OpenShell, so it counts too, until the
    # user allows it. So do the OpenClaw services the gateway calls on its
    # own (`--call`), named in no declaration either. It calls them once at
    # start, before the lock, and a row is made only for a request stored
    # after adoption, so they are in the proposal's would-be violations
    # but count only if called again. Nothing else may count.
    guard = Guardrail(base, token, ours)
    proposal = guard.adopt(version["alignment_version_id"])
    hosts = {MODEL_HOST, *args.call}
    expected = ({("out_of_spec_calls", host) for host in hosts}
                | {("service_ports", item) for item in args.listener})
    would_be = {(v["rule"], v["item"]) for v in proposal["would_be_violations"]}
    if would_be != expected:
        sys.exit(f"FAIL: the proposal would be violated by {sorted(would_be)}, expected {sorted(expected)}")
    started = {("out_of_spec_calls", host) for host in args.call}
    guard.wait_for_rows(f"its calls to {MODEL_HOST} and its listeners {args.listener} are the "
                        "counting rows", expected - started, exact=True, may_count=started)
    called = {item for rule, item in guard.rows() if rule == "out_of_spec_calls" and item in hosts}
    if called - {MODEL_HOST}:
        guard.allow_all("out_of_spec_calls", called)
    else:
        guard.allow("out_of_spec_calls", MODEL_HOST)
    if args.listener:
        guard.allow_all("service_ports", set(args.listener))
    guard.wait_for_state("held", f"with {sorted(called)} and {args.listener} allowed, the "
                                 "guardrail reads Held")

    # ---- the turns go on, and nothing moves -------------------------------
    newest_before = max((r["id"] for r in marked("tool")), default=0)
    deadline = time.monotonic() + args.watch
    fresh_asps = 0
    while time.monotonic() < deadline:
        for item in [i for i in agent_asps() if i["asp_id"] not in seen]:
            seen.add(item["asp_id"])
            fresh_asps += 1
            state = api(base, f"/api/asps/{item['asp_id']}/state")
            if state.get("state") != "ALIGNED":
                print(json.dumps(state, indent=1)[:20000])
                sys.exit(f"FAIL: {item['asp_id']} is {state.get('state')} while the agent only "
                         "took its usual turns, expected ALIGNED")
        detail = guard.detail()
        if detail["state"] != "held":
            print(json.dumps(detail, indent=1)[:20000])
            sys.exit(f"FAIL: the guardrail turned {detail['state']} while the agent only took "
                     "its usual turns")
        time.sleep(5)
    turns = sum(1 for r in marked("tool") if r["id"] > newest_before)
    if turns < 1:
        sys.exit(f"FAIL: no new tool-call reply was captured in {args.watch:.0f}s: the agent "
                 "stopped, or the collector did")
    if fresh_asps < 1:
        sys.exit(f"FAIL: no new ASP arrived in {args.watch:.0f}s of the agent's turns: "
                 "the scanner stopped delivering")
    print(f"ok:   {args.watch:.0f}s more of the agent's turns ({turns}+ captured tool-call "
          f"replies, {fresh_asps} new ASP(s)): every ASP ALIGNED, the guardrail Held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
