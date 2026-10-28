#!/usr/bin/env python3
"""DR-259 (DR-194 M4) acceptance against a running stack: RailDash's
**Download as OpenShell policy** for the sandboxed agent's guardrail in
force. Writes the file to --out for the job's OpenShell steps (a sandbox
created from it, and `policy set` then rollback on the agent's sandbox),
which are what prove OpenShell takes it. Here only what the file must say:
the imported policy's static sections, the agent's host in audit with its
binary, no loopback rule. Reads the token from RAILDASH_TOKEN_VALUE;
stdlib only, like stack_acceptance.py.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request


def get(base: str, path: str) -> urllib.request.addinfourl:
    request = urllib.request.Request(base + path, headers={"X-RailDash-Token": os.environ["RAILDASH_TOKEN_VALUE"]})
    return urllib.request.urlopen(request, timeout=30)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--agent-key", default="my-agent")
    parser.add_argument("--agent-ref", help="the agent's ref, instead of finding it by --agent-key")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    with get(args.url, "/api/guardrails") as response:
        agents = json.load(response)

    def ours(identity: dict) -> bool:  # as stack_acceptance.py's --agent key:<name>
        kind, value = identity.get("kind"), identity.get("value")
        return (kind == "local_agent_key" and value == args.agent_key) or (
            kind == "local_agent_keys" and isinstance(value, list) and args.agent_key in value)

    refs = [a["agent_ref"] for a in agents if ours(a.get("agent_identity") or {})]
    if args.agent_ref:
        refs = [args.agent_ref]
    if len(refs) != 1:
        sys.exit(f"FAIL  expected one guardrail agent with key {args.agent_key}, got {len(refs)}")
    with get(args.url, f"/api/guardrails/{refs[0]}/openshell-policy/export") as response:
        disposition = response.headers.get("Content-Disposition", "")
        text = response.read().decode()
    with open(args.out, "w") as out:
        out.write(text)
    lines = text.splitlines()
    checks = {
        "an attachment named openshell-policy-<version>.yaml": 'filename="openshell-policy-' in disposition,
        "the header says where it came from": lines[0].startswith("# OpenShell policy exported by RailDash"),
        "the imported policy's static sections, /data included": "filesystem_policy:" in text and "- /data" in text,
        "api.github.com is an endpoint": "- host: api.github.com" in text,
        "every L7 endpoint is audit": "enforcement: audit" in text and "enforcement: enforce" not in text,
        "with the agent's binary": "path: /usr/local/bin/my-agent-bin" in text,
        "no rule for its loopback demo server": "host: 127.0.0.1" not in text
        and any("127.0.0.1" in line for line in lines if line.startswith("#")),
        "the rollback goes through policy get's JSON": "--output json | jq -e .policy" in text,
    }
    failed = [what for what, ok in checks.items() if not ok]
    if failed:
        print(text)
        sys.exit("FAIL  the export: " + "; ".join(failed))
    print(f"ok    RailDash exported the guardrail in force as an OpenShell policy ({len(lines)} lines): "
          + "; ".join(checks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
