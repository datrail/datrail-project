#!/usr/bin/env python3
"""Walk Part A of docs/demo/DEMO_RUNBOOK.md as a presenter does, in a browser.

The stack acceptance (tests/stack_acceptance.py) checks the same sequence
through RailDash's API with its own commands. This walk checks the runbook
itself: it runs Part A's fenced command blocks word for word, in order, at
the stack's default settings and the images the install pins, clicks the
buttons the runbook names in RailDash's page (Playwright's Chromium), and
checks that the page then shows what the runbook says it shows. RailDash's
API is read only to know when a step has landed and to say exactly what
differs when it hasn't. A screenshot of the page is kept at every step.

Run it from the checkout the runbook's commands expect (`~/datrail-project`)
on a disposable host: A0 runs `docker compose down -v`.

EVIDENCE_DIR receives the transcript, timings and screenshots.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable
from urllib.error import URLError
from urllib.request import Request, urlopen

from playwright.sync_api import Page, sync_playwright

BASE = os.environ.get("WALK_URL", "http://127.0.0.1:8000")
CHECKOUT = Path(os.environ.get("WALK_CHECKOUT", Path.home() / "datrail-project"))
RUNBOOK = CHECKOUT / "docs/demo/DEMO_RUNBOOK.md"
EVIDENCE = Path(os.environ["EVIDENCE_DIR"])
# At the stack's default SCAN_INTERVAL (60 s) a step that waits for a scan
# takes up to a minute, and the runbook says so; three scans is the bound.
SCAN_WAIT = float(os.environ.get("WALK_SCAN_WAIT", "200"))

DEMO_SCRIPT = "/opt/railmon/tools/local-demo/demo_client.py"
TOOL = "mcp__demo__"
MCP_ENDPOINT = "127.0.0.1/mcp"

started = time.monotonic()
transcript = (EVIDENCE / "transcript.txt").open("a")
timings = (EVIDENCE / "timings.txt").open("a")


def note(text: str) -> None:
    print(text, flush=True)
    transcript.write(text + "\n")
    transcript.flush()


def say(text: str) -> None:
    note(f"\n## {text}")


def fail(text: str) -> None:
    note(f"FAIL: {text}")
    sys.exit(1)


def timed(what: str, since: float) -> None:
    timings.write(f"{time.monotonic() - since:6.0f}s  {what}\n")
    timings.flush()


# ---- the runbook ------------------------------------------------------------

def part_a_blocks() -> dict[str, list[str]]:
    """Part A's fenced ```bash blocks, by step (`A0` ... `A8`), in order."""
    text = RUNBOOK.read_text()
    match = re.search(r"^## Part A\b.*?$(.*?)^## Part B\b", text, re.S | re.M)
    if not match:
        fail(f"{RUNBOOK} has no Part A followed by a Part B")
    steps: dict[str, list[str]] = {}
    for step in re.split(r"^### ", match.group(1), flags=re.M)[1:]:
        name = step.split(".", 1)[0].strip()
        steps[name] = re.findall(r"^```bash\n(.*?)^```", step, re.S | re.M)
    return steps


BLOCKS = part_a_blocks()


def run_block(step: str, index: int, *, contains: str) -> None:
    """Run the step's `index`th block as the runbook gives it. `contains` is
    a fragment the walk expects in it, so a reordered or rewritten step
    fails here, where it changed, rather than as a wrong row later."""
    blocks = BLOCKS.get(step) or []
    if index >= len(blocks):
        fail(f"the runbook's {step} has {len(blocks)} command block(s), the walk runs block {index + 1}")
    block = blocks[index]
    if contains not in block:
        fail(f"the runbook's {step} block {index + 1} no longer contains {contains!r}:\n{block}")
    note(f"$ {block.rstrip()}    [{step}, block {index + 1}]")
    t0 = time.monotonic()
    result = subprocess.run(["bash", "-c", block], cwd=CHECKOUT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    note(result.stdout.rstrip())
    timed(f"{step} block {index + 1}", t0)
    if result.returncode != 0:
        fail(f"exit {result.returncode}: {step} block {index + 1}")


# ---- RailDash's API, read to know when a step landed -------------------------

def api(path: str, body: dict | None = None) -> Any:
    headers = {"Content-Type": "application/json", "X-RailDash-Token": TOKEN} if TOKEN else {}
    data = json.dumps(body).encode() if body is not None else None
    request = Request(BASE + path, data=data, headers=headers,
                      method="POST" if body is not None else "GET")
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def page_token() -> str:
    with urlopen(BASE + "/", timeout=10) as response:
        found = re.search(r'<meta name="raildash-token" content="([^"]+)"', response.read().decode())
    return found.group(1) if found else ""


TOKEN = ""


def wait_for(what: str, check: Callable[[], Any], timeout: float = SCAN_WAIT) -> Any:
    t0 = time.monotonic()
    last: Any = None
    while True:
        try:
            result = check()
        except (URLError, OSError, KeyError, ValueError, IndexError, TypeError) as error:
            result, last = None, error
        if result:
            note(f"ok after {time.monotonic() - t0:.0f}s: {what}")
            timed(f"until: {what}", t0)
            return result
        if time.monotonic() - t0 > timeout:
            if last is not None:
                note(f"      (last error: {last})")
            fail(f"not within {timeout:.0f}s: {what}")
        time.sleep(5)


def demo_asps() -> list[dict]:
    """The demo agent's ASPs, newest first."""
    out = []
    for asp in api("/api/asps?limit=500")["items"]:
        who = asp.get("agent_identity") or {}
        value = who.get("value")
        if who.get("kind") == "deployment_compose" and isinstance(value, dict) \
                and value.get("service") == "demo-agent":
            out.append(asp)
    return out


def answered(asp_id: str, name: str) -> list[dict]:
    attribute = api(f"/api/asps/{asp_id}/bundle")["attributes"][name]
    return (attribute.get("value") or []) if attribute.get("status") in ("ANSWERED", "PARTIAL") else []


def guardrail() -> dict:
    agents = [a for a in api("/api/guardrails")
              if ((a.get("agent_identity") or {}).get("value") or {}).get("service") == "demo-agent"]
    if len(agents) != 1:
        raise KeyError(f"{len(agents)} demo-agent guardrails listed")
    return api(f"/api/guardrails/{agents[0]['agent_ref']}")


def counting(detail: dict) -> set[tuple[str, str]]:
    return {(r["rule"], r["item"]) for r in detail["rows"] if r["counts"]}


def rows_are(what: str, want: set[tuple[str, str]], state: str = "violated") -> dict:
    """Wait until exactly `want` count and the guardrail reads `state`."""
    def check() -> dict | None:
        detail = guardrail()
        extra = counting(detail) - want
        if extra:
            fail(f"{what}: rows the runbook doesn't name count: {sorted(extra)}")
        return detail if detail["state"] == state and counting(detail) == want else None
    detail = wait_for(what, check)
    note(f"      rows: {sorted(counting(detail))}; rules: "
         f"{ {rule: r['state'] for rule, r in (detail['rules'] or {}).items()} }")
    return detail


# ---- the page --------------------------------------------------------------

shot_number = 0


def screenshot(page: Page, name: str) -> None:
    global shot_number
    shot_number += 1
    path = EVIDENCE / f"{shot_number:02d}-{name}.png"
    page.screenshot(path=str(path), full_page=True)
    note(f"screenshot: {path.name}")


def page_shows(page: Page, what: str, *needles: str, timeout: float = 90) -> None:
    """Wait until the page's visible text has every needle, case-blind (the
    runbook writes some labels as the page's CSS shows them, in capitals).
    The page refreshes itself; it is reloaded once if that doesn't do it."""
    t0 = time.monotonic()
    reloaded = False
    while True:
        text = page.inner_text("body").lower()
        missing = [n for n in needles if n.lower() not in text]
        if not missing:
            note(f"ok after {time.monotonic() - t0:.0f}s: the page shows {what}")
            return
        if not reloaded and time.monotonic() - t0 > timeout / 2:
            page.reload(wait_until="networkidle")
            reloaded = True
        if time.monotonic() - t0 > timeout:
            screenshot(page, "missing")
            fail(f"the page doesn't show {what}: missing {missing}")
        page.wait_for_timeout(2000)


def click(page: Page, label: str, *, within: str = "body", exact: bool = True) -> None:
    button = page.locator(within).get_by_role("button", name=label, exact=exact)
    if button.count() != 1:
        screenshot(page, "button")
        fail(f"{button.count()} buttons {label!r} within {within}, expected one")
    button.scroll_into_view_if_needed()
    button.click()
    note(f"clicked: {label}")


# ---- Part A ------------------------------------------------------------------

def main() -> int:
    global TOKEN
    say("A0. Start clean")
    run_block("A0", 0, contains="docker compose down -v && docker compose up -d")
    run_block("A0", 1, contains="docker compose ps")
    wait_for("RailDash is up", lambda: api("/webhook/health"), 300)
    TOKEN = page_token()
    if not TOKEN:
        fail("the dashboard page carries no raildash-token")

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        page.goto(BASE + "/", wait_until="networkidle")

        say("A1. What you see")
        wait_for("the demo agent's POSTs to /v1/demo, /v1/demo/other and /mcp, status 200", lambda: {
            r.get("path") for r in api("/api/interactions?limit=500")["items"]
            if r.get("method") == "POST" and r.get("status_code") == 200
        } >= {"/v1/demo", "/v1/demo/other", "/mcp"}, 300)

        def second_asp() -> str | None:
            asps = demo_asps()
            if len(asps) < 2:
                return None
            newest = asps[0]["asp_id"]
            ports = {l.get("port") for l in answered(newest, "observed_listeners")}
            files = {f.get("path") for f in answered(newest, "observed_file_access")}
            return newest if 8443 in ports and DEMO_SCRIPT in files else None
        newest = wait_for("a second ASP, with 127.0.0.1:8443 listening and demo_client.py read",
                          second_asp, 300)
        page_shows(page, "the interaction log, the ASP panel and the observed data action",
                   "/v1/demo", "/v1/demo/other", "/mcp", "Agent Security Profile alignment",
                   "Observed security profile", f"{TOOL}read_doc")
        screenshot(page, "a1-what-you-see")

        say("A2. Lock the baseline")
        page.reload(wait_until="networkidle")
        click(page, "Lock this as your alignment baseline")
        def aligned() -> bool:
            asps = demo_asps()
            return api(f"/api/asps/{asps[0]['asp_id']}/state").get("state") == "ALIGNED"
        wait_for("the newest ASP is ALIGNED with the locked baseline", aligned, 60)
        page_shows(page, "ALIGNED · v1.0 (active)", "Aligned", "v1.0", "active")
        note(f"      locked on {newest}'s card")
        screenshot(page, "a2-aligned")

        say("A3. Drift")
        seen = {a["asp_id"] for a in demo_asps()}
        run_block("A3", 0, contains="http.server 9000")

        def drifted() -> dict | None:
            for asp in demo_asps():
                if asp["asp_id"] in seen:
                    continue
                state = api(f"/api/asps/{asp['asp_id']}/state")
                names = [c.get("name") for c in (state.get("drift") or {}).get("changes") or []]
                if state.get("state") == "DRIFT_DETECTED" and "observed_listeners" in names:
                    return {"asp_id": asp["asp_id"], "changes": names}
            return None
        drift = wait_for("the next scan shows DRIFT DETECTED with observed_listeners", drifted)
        note(f"      changes: {drift['changes']}")
        unexpected = set(drift["changes"]) - {"observed_listeners", "observed_file_access"}
        if unexpected:
            fail(f"the runbook names observed_listeners and observed_file_access; the drift also has {sorted(unexpected)}")
        page_shows(page, "DRIFT DETECTED with observed_listeners", "Drift detected", "observed_listeners")
        screenshot(page, "a3-drift")

        say("A4. Data Guardrail")
        proposal = wait_for("a guardrail is proposed", lambda: guardrail()["proposal"], 60)
        would_be = {v["item"] for v in proposal["would_be_violations"]}
        note(f"      would be violations: {sorted(would_be)}")
        if would_be != {"tcp/127.0.0.1/8443", "127.0.0.1"}:
            fail(f"the runbook names two would-be violations, tcp/127.0.0.1/8443 and 127.0.0.1; the proposal has {sorted(would_be)}")
        blocked = [b["tool"] for b in proposal.get("data_actions_blocked") or []]
        if f"{TOOL}upload_file" not in blocked:
            fail(f"the runbook says upload_file is blocked until allowed; blocked: {blocked}")
        page_shows(page, "the proposal", "Adopt a guardrail for this agent?", "Uploads",
                   "Saved files", "__pycache__", "Data actions allowed", "read_doc: read",
                   "upload_file", "tcp/127.0.0.1/8443")
        screenshot(page, "a4-proposal")
        click(page, "Adopt", within="section.guardrail-proposal")
        detail = rows_are("Adopt: g1, Violated by 9000, 8443 and 127.0.0.1", {
            ("service_ports", "tcp/127.0.0.1/9000"), ("service_ports", "tcp/127.0.0.1/8443"),
            ("out_of_spec_calls", "127.0.0.1")})
        if detail["active"]["guardrail"]["version"] != "g1":
            fail(f"Adopt made {detail['active']['guardrail']['version']}, the runbook says g1")
        page_shows(page, "Violated, with Allow all 2", "Violated", "Allow all 2")
        screenshot(page, "a4-violated")
        click(page, "Allow all 2")
        wait_for("Allow all 2 makes g2", lambda: guardrail()["active"]["guardrail"]["version"] == "g2", 60)
        page.reload(wait_until="networkidle")
        click(page, "Allow this", within='tr:has(td > code:text-is("127.0.0.1"))')
        wait_for("Allow this makes g3", lambda: guardrail()["active"]["guardrail"]["version"] == "g3", 60)
        rows_are("HELD within a minute", set(), state="held")
        page_shows(page, "HELD", "Held")
        screenshot(page, "a4-held")

        say("A5. Violations")
        run_block("A5", 0, contains="/data/report.zip")
        run_block("A5", 1, contains="exfil.example")
        exfil = {("saved_files", "/data/report.zip"), ("uploads", "exfil.example"),
                 ("out_of_spec_calls", "exfil.example")}
        detail = rows_are("VIOLATED: report.zip saved, uploaded to exfil.example", exfil)
        rules = {rule: r["state"] for rule, r in detail["rules"].items()}
        if rules.get("service_ports") != "held" or rules.get("data_actions") != "held":
            fail(f"the runbook says Service ports and Data actions stay held: {rules}")
        page_shows(page, "the three rows", "/data/report.zip", "exfil.example")
        screenshot(page, "a5-violated")
        run_block("A5", 2, contains="search.example")
        searched = exfil | {("out_of_spec_calls", "search.example")}
        detail = rows_are("search.example under Out-of-spec calls only", searched)
        if ("uploads", "search.example") in {(r["rule"], r["item"]) for r in detail["rows"]}:
            fail("the parameters POST to search.example was judged an upload")
        page_shows(page, "search.example", "search.example")
        screenshot(page, "a5-search")

        say("A6. Data actions")
        run_block("A6", 0, contains="upload_file")
        time.sleep(3)
        run_block("A6", 1, contains="export_all")
        time.sleep(3)
        run_block("A6", 2, contains="--garbage")
        three = searched | {("data_actions", f"{TOOL}upload_file · upload"),
                            ("data_actions", f"{TOOL}export_all · unclassified"),
                            ("data_actions", f"{MCP_ENDPOINT} · unreadable call")}
        not_offered = ("data_actions", f"{TOOL}export_all · not offered by {MCP_ENDPOINT}")

        def three_rows() -> dict | None:
            detail = guardrail()
            extra = counting(detail) - three - {not_offered}
            if extra:
                fail(f"A6: rows the runbook doesn't name count: {sorted(extra)}")
            return detail if three <= counting(detail) else None
        detail = wait_for("DATA ACTIONS shows the three rows", three_rows, 60)
        upload = next(r for r in detail["rows"] if r["item"] == f"{TOOL}upload_file · upload")
        if upload["detail"].get("content_kinds") != ["image"]:
            fail(f"the runbook says the upload carries an image: {upload['detail']}")
        page_shows(page, "the three data-action rows", "upload_file · upload",
                   "export_all · unclassified", f"{MCP_ENDPOINT} · unreadable call")
        screenshot(page, "a6-three-rows")
        detail = rows_are("a minute later, export_all is not offered", three | {not_offered})
        if detail["rules"]["data_actions"]["state"] != "violated":
            fail(f"the runbook says Data actions turns violated: {detail['rules']['data_actions']}")
        page_shows(page, "not offered", f"not offered by {MCP_ENDPOINT}")
        screenshot(page, "a6-not-offered")

        say("A7. Egress")
        reading = (guardrail().get("egress") or {}).get("reading") or {}
        if reading.get("level") != "open":
            fail(f"the runbook says Egress reads Open: {reading}")
        page_shows(page, "Egress: Open", "Egress", "Open")
        click(page, "Require containment")
        detail = rows_are("Require containment: g4, egress containment violated",
                          three | {not_offered, ("egress_containment", "open")})
        if detail["active"]["guardrail"]["version"] != "g4":
            fail(f"Require containment made {detail['active']['guardrail']['version']}, the runbook says g4")
        page_shows(page, "egress containment violated", "Egress containment")
        screenshot(page, "a7-egress")
        browser.close()

    say("Done")
    note(f"Part A walked in {time.monotonic() - started:.0f}s")
    timed("the whole walk", started)
    return 0


if __name__ == "__main__":
    sys.exit(main())
