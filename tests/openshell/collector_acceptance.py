#!/usr/bin/env python3
"""DR-249 acceptance against a running stack: `railmon openshell`'s posts
reach RailDash for the sandboxed agent. Reads the token from
RAILDASH_TOKEN_VALUE; stdlib only, like stack_acceptance.py.

--phase policy  the policy shows as read by the collector, with the rule
                that lets the agent reach api.github.com:443
--phase l7      the agent's POST its read-only rule refuses (DR-250): the
                capture carries the request with the supervisor's answer, and
                OpenShell's L7 denial of it shows under Blocked by OpenShell
--phase denial  after that rule is removed: a newer revision without it,
                and a denial of api.github.com under Blocked by OpenShell
--phase recreated  a new sandbox under the same name: the agent's calls from
                its new container arrive (--since), without a restart
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request


def get(base: str, path: str) -> object:
    request = urllib.request.Request(base + path, headers={"X-RailDash-Token": os.environ["RAILDASH_TOKEN_VALUE"]})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def details(base: str) -> list[dict]:
    return [get(base, f"/api/guardrails/{agent['agent_ref']}") for agent in get(base, "/api/guardrails")]


def github(endpoints: list[dict]) -> bool:
    return any(e["host"] == "api.github.com" and 443 in e["ports"] for e in endpoints)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--phase", choices=("policy", "l7", "denial", "recreated"), required=True)
    parser.add_argument("--since", help="--phase recreated: RFC 3339, when the sandbox was recreated")
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    deadline = time.time() + args.timeout
    seen = "nothing"
    while time.time() < deadline:
        if args.phase in ("l7", "recreated"):
            rows = get(args.url, "/api/interactions?limit=500")["items"]
            if args.phase == "recreated":
                fresh = [r for r in rows if r.get("path") in ("/v1/demo", "/v1/demo/other")
                         and (r.get("timestamp") or "") >= args.since]
                seen = f"{len(fresh)} demo calls since {args.since}"
                if fresh:
                    print(f"ok    the recreated sandbox is followed: {len(fresh)} of its agent's calls "
                          f"arrived after {args.since}, with no restart")
                    return 0
                time.sleep(3)
                continue
            posts = [r for r in rows if "api.github.com" in (r.get("host") or "")
                     and r.get("method") == "POST" and r.get("path") == "/markdown"]
            groups = [g for d in details(args.url) for g in ((d.get("openshell_denials") or {}).get("groups") or [])
                      if g["host"] == "api.github.com" and "POST /markdown" in g["requests"]]
            seen = f"{len(posts)} captured POST /markdown, {len(groups)} L7 denial groups"
            if posts and groups:
                print(f"ok    the L7-denied POST /markdown is captured too (answered "
                      f"{sorted({r.get('status_code') for r in posts}, key=str)}), and OpenShell's denial "
                      f"shows: {'; '.join(groups[0]['reasons'])}")
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
                hits = [g for g in denials["groups"] if g["host"] == "api.github.com"]
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
