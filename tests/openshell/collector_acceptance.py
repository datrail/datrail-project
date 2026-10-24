#!/usr/bin/env python3
"""DR-249 acceptance against a running stack: `railmon openshell`'s posts
reach RailDash for the sandboxed agent. Reads the token from
RAILDASH_TOKEN_VALUE; stdlib only, like stack_acceptance.py.

--phase policy  the policy shows as read by the collector, with the rule
                that lets the agent reach api.github.com:443
--phase denial  after that rule is removed: a newer revision without it,
                and a denial of api.github.com under Blocked by OpenShell
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
    parser.add_argument("--phase", choices=("policy", "denial"), required=True)
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    deadline = time.time() + args.timeout
    seen = "nothing"
    while time.time() < deadline:
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
