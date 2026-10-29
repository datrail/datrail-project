#!/usr/bin/env python3
"""DR-249 acceptance against a running stack: `railmon openshell`'s posts
reach RailDash for the sandboxed agent. Reads the token from
RAILDASH_TOKEN_VALUE; stdlib only, like stack_acceptance.py.

--phase policy  the policy shows as read by the collector, with the rule
                that lets the agent reach api.github.com:443
--phase l7      the agent's POST its read-only rule refuses (DR-250): the
                capture carries the request with the supervisor's answer,
                OpenShell's L7 denial of it shows under Blocked by OpenShell,
                and the guardrail in force has no row for it (DR-261)
--phase denial  after that rule is removed: a newer revision without it,
                and a denial of api.github.com under Blocked by OpenShell
--phase recreated  a new sandbox under the same name: the agent's calls from
                its new container arrive (--since), without a restart
--phase allow-list  the newest ASP's egress_containment carries the
                sandbox's allow-list, read from OpenShell by the collector
                and carried by railmon scan (DR-266), api.github.com:443
                with the agent's binary among it
--phase allow-list-removed  after that rule is removed: a newer ASP whose
                allow-list no longer has it, so it is OpenShell's policy
                now, not a copy
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from datetime import datetime


def get(base: str, path: str) -> object:
    request = urllib.request.Request(base + path, headers={"X-RailDash-Token": os.environ["RAILDASH_TOKEN_VALUE"]})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def details(base: str) -> list[dict]:
    return [get(base, f"/api/guardrails/{agent['agent_ref']}") for agent in get(base, "/api/guardrails")]


def instant(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def github(endpoints: list[dict]) -> bool:
    return any(e["host"] == "api.github.com" and 443 in e["ports"] for e in endpoints)


def newest_egress(base: str) -> dict | None:
    """The newest ASP's egress_containment (v1 or v2: sandbox-scoped)."""
    items = get(base, "/api/asps?limit=1")["items"]
    if not items:
        return None
    bundle = get(base, f"/api/asps/{items[0]['asp_id']}/bundle")
    attributes = bundle.get("attributes") or (bundle.get("sandbox") or {}).get("attributes") or {}
    return attributes.get("egress_containment")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--phase", choices=("policy", "l7", "denial", "recreated", "allow-list",
                                            "allow-list-removed"), required=True)
    parser.add_argument("--since", help="--phase recreated: RFC 3339, when the sandbox was recreated")
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    deadline = time.time() + args.timeout
    seen = "nothing"
    while time.time() < deadline:
        if args.phase in ("allow-list", "allow-list-removed"):
            attribute = newest_egress(args.url) or {}
            value = attribute.get("value") or {}
            allow_list = value.get("allow_list")
            seen = f"level {value.get('level')}, allow_list {allow_list!r:.300}, reasons {value.get('reasons')}"
            if isinstance(allow_list, list):
                hits = [e for e in allow_list if e["host"] == "api.github.com" and e["port"] == 443]
                if args.phase == "allow-list" and hits and hits[0]["binaries"]:
                    print(f"ok    the newest ASP carries the sandbox's allow-list from OpenShell "
                          f"({len(allow_list)} entries; api.github.com:443 {hits[0]['access'] or hits[0]['rules']}, "
                          f"{', '.join(hits[0]['binaries'])})")
                    return 0
                if args.phase == "allow-list-removed" and not hits:
                    print(f"ok    with github_api removed, a newer ASP's allow-list ({len(allow_list)} entries) "
                          "no longer has api.github.com:443")
                    return 0
            time.sleep(3)
            continue
        if args.phase in ("l7", "recreated"):
            rows = get(args.url, "/api/interactions?limit=500")["items"]
            if args.phase == "recreated":
                since = instant(args.since)
                fresh = [r for r in rows if r.get("path") in ("/v1/demo", "/v1/demo/other")
                         and r.get("timestamp") and instant(r["timestamp"]) >= since]
                seen = f"{len(fresh)} demo calls since {args.since}"
                if fresh:
                    print(f"ok    the recreated sandbox is followed: {len(fresh)} of its agent's calls "
                          f"arrived after {args.since}, with no restart")
                    return 0
                time.sleep(3)
                continue
            posts = [r for r in rows if "api.github.com" in (r.get("host") or "")
                     and r.get("method") == "POST" and r.get("path") == "/markdown"]
            denied = [(d, g) for d in details(args.url) for g in ((d.get("openshell_denials") or {}).get("groups") or [])
                      if g["host"] == "api.github.com" and "POST /markdown" in g["requests"]]
            held = [d["openshell_held"] for d, _ in denied if d.get("openshell_held")]
            seen = f"{len(posts)} captured POST /markdown, {len(denied)} L7 denial groups, held {held}"
            # DR-261 (Lebin's DR-194 Q1): the captured request OpenShell
            # refused doesn't count against the guardrail in force. RailDash
            # holds it until OpenShell's denial of it arrives, then drops it,
            # so once nothing is held it must be in no uploads row.
            if posts and denied and not held:
                detail, group = denied[0]
                if detail.get("active") is None or "openshell_held" not in detail:
                    print(f"FAIL  no guardrail in force, or a RailDash without DR-261: {seen}", file=sys.stderr)
                    return 1
                judged = [r for r in detail["rows"] if r["item"] == "api.github.com"]
                if judged:
                    print(f"FAIL  the POST OpenShell blocked was judged: {judged}", file=sys.stderr)
                    return 1
                print(f"ok    the L7-denied POST /markdown is captured too (answered "
                      f"{sorted({r.get('status_code') for r in posts}, key=str)}), and OpenShell's denial "
                      f"shows: {'; '.join(group['reasons'])}")
                print(f"ok    the guardrail in force ({detail['active']['guardrail']['version']}) has no row for it: "
                      "a request OpenShell blocked isn't judged")
                return 0
            time.sleep(3)
            continue
        for detail in details(args.url):
            policy = detail.get("openshell_policy")
            denials = detail.get("openshell_denials")
            if policy is None:
                continue
            seen = f"policy source={policy['source']} revision={policy['revision']} " \
                   f"denial groups={len((denials or {}).get('groups', []))}"
            if policy["source"] != "collector":
                continue
            if args.phase == "policy" and github(policy["endpoints"]):
                print(f"ok    railmon openshell posted revision {policy['revision']} of the sandbox's "
                      f"policy ({len(policy['endpoints'])} endpoints, api.github.com:443 among them)")
                return 0
            if args.phase == "denial" and not github(policy["endpoints"]) and denials:
                # Not the L7 POST denial of the step before: one at L4, which
                # only the removed rule explains.
                hits = [g for g in denials["groups"] if g["host"] == "api.github.com"
                        and any(not reason.startswith("L7_") for reason in g["reasons"])]
                if hits:
                    print(f"ok    revision {policy['revision']} without github_api arrived, and OpenShell's "
                          f"denial of api.github.com:{hits[0]['port']} ({hits[0]['binary']}, "
                          f"{'; '.join(hits[0]['reasons'])}) shows under Blocked by OpenShell")
                    print(f"ok    PARTIAL spans shown: {len(denials['partial'])}")
                    return 0
        time.sleep(3)
    print(f"FAIL  phase {args.phase}: not seen within {args.timeout:g} s (last: {seen})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
