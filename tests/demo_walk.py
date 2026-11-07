#!/usr/bin/env python3
"""Walk Part A or Part C of docs/demo/DEMO_RUNBOOK.md as a presenter does,
in a browser (WALK_PART, A by default).

The stack acceptance (tests/stack_acceptance.py) checks the same sequence
through RailDash's API with its own commands. This walk checks the runbook
itself: it runs the part's fenced command blocks word for word, in order, at
the stack's default settings and the images the install pins, clicks the
buttons the runbook names in RailDash's page (Playwright's Chromium), and
checks that the page then shows what the runbook says it shows. RailDash's
API is read to know when a step has landed, and to check what the runbook
says that the page doesn't spell out (version labels, the content kind, the
egress level), saying exactly what differs when it doesn't match. A screenshot of the page is kept at every step.

Run it from the checkout the runbook's commands expect (`~/datrail-project`)
on a disposable host: A0 and C2 run `docker compose down -v`. Part C needs
OpenShell's gateway running (tests/openshell/install.sh, C1's CI form) and
`jq` on PATH.

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

PART = os.environ.get("WALK_PART", "A")
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

# Where each part ends: the next part's heading, or Part C's closing rule.
PART_END = {"A": r"^## Part B\b", "C": r"^---$"}


def part_blocks(part: str, lang: str = "bash") -> dict[str, list[str]]:
    """The part's fenced ```<lang> blocks, by step (`A0` ... `A8`), in order."""
    text = RUNBOOK.read_text()
    match = re.search(rf"^## Part {part}\b.*?$(.*?){PART_END[part]}", text, re.S | re.M)
    if not match:
        fail(f"{RUNBOOK} has no Part {part} ending where the walk expects")
    steps: dict[str, list[str]] = {}
    for step in re.split(r"^### ", match.group(1), flags=re.M)[1:]:
        name = step.split(".", 1)[0].strip()
        steps[name] = re.findall(rf"^```{lang}\n(.*?)^```", step, re.S | re.M)
    return steps


# Part C reuses Part A's A3 block, with `$A` for the demo agent's container.
BLOCKS = {**part_blocks("A"), **(part_blocks("C") if PART == "C" else {})}
# Where a block runs: the runbook's shell, with what an earlier step set in it.
SHELL_ENV = dict(os.environ)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def run_block(step: str, index: int, *, contains: str,
              replace: dict[str, str] | None = None, check: bool = True) -> str:
    """Run the step's `index`th block as the runbook gives it, and return its
    output with colours stripped. `contains` is a fragment the walk expects
    in it, so a reordered or rewritten step fails here, where it changed,
    rather than as a wrong row later. `replace` fills in what the runbook
    leaves to the presenter (`<version>`, `N`) or swaps the container name
    for C7's reuse of A3; each one must be there to replace."""
    blocks = BLOCKS.get(step) or []
    if index >= len(blocks):
        fail(f"the runbook's {step} has {len(blocks)} command block(s), the walk runs block {index + 1}")
    block = blocks[index]
    if contains not in block:
        fail(f"the runbook's {step} block {index + 1} no longer contains {contains!r}:\n{block}")
    for old, new in (replace or {}).items():
        if old not in block:
            fail(f"the runbook's {step} block {index + 1} has no {old!r} to fill in:\n{block}")
        block = block.replace(old, new)
    note(f"$ {block.rstrip()}    [{step}, block {index + 1}]")
    t0 = time.monotonic()
    result = subprocess.run(["bash", "-c", block], cwd=CHECKOUT, text=True, env=SHELL_ENV,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = ANSI.sub("", result.stdout)
    note(out.rstrip())
    timed(f"{step} block {index + 1}", t0)
    if check and result.returncode != 0:
        fail(f"exit {result.returncode}: {step} block {index + 1}")
    return out


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


def wait_for(what: str, check: Callable[[], Any], timeout: float = SCAN_WAIT,
             last_seen: Callable[[], str] | None = None) -> Any:
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
            if last_seen is not None:
                note(f"      (last seen: {last_seen()})")
            fail(f"not within {timeout:.0f}s: {what}")
        time.sleep(5)


def ours(who: dict) -> bool:
    """The walked agent: Part A's compose service demo-agent, or Part C's
    sandbox, keyed by its name (C5)."""
    kind, value = who.get("kind"), who.get("value")
    if PART == "C":
        return (kind == "local_agent_key" and value == "my-agent") or (
            kind == "local_agent_keys" and isinstance(value, list) and "my-agent" in value)
    return kind == "deployment_compose" and isinstance(value, dict) and value.get("service") == "demo-agent"


def demo_asps() -> list[dict]:
    """The walked agent's ASPs, newest first."""
    return [asp for asp in api("/api/asps?limit=500")["items"] if ours(asp.get("agent_identity") or {})]


def answered(asp_id: str, name: str) -> list[dict]:
    attribute = api(f"/api/asps/{asp_id}/bundle")["attributes"][name]
    return (attribute.get("value") or []) if attribute.get("status") in ("ANSWERED", "PARTIAL") else []


def guardrail() -> dict:
    agents = [a for a in api("/api/guardrails") if ours(a.get("agent_identity") or {})]
    if len(agents) != 1:
        raise KeyError(f"{len(agents)} guardrails listed for the walked agent")
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
    def last_seen() -> str:
        try:
            detail = guardrail()
            return f"{detail['state']}, counting {sorted(counting(detail))}"
        except (URLError, OSError, KeyError, ValueError) as error:
            return f"(guardrail unreadable: {error})"
    detail = wait_for(what, check, last_seen=last_seen)
    note(f"      rows: {sorted(counting(detail))}; rules: "
         f"{ {rule: r['state'] for rule, r in (detail['rules'] or {}).items()} }")
    return detail


# ---- the page --------------------------------------------------------------

shot_number = 0

# RailDash's top bar and session rail are sticky, so a full-page capture taken
# while scrolled draws them partway down the page, over whatever card is there
# (the guardrail card's badge, in practice). Unstick them for the capture only.
UNSTICK = ".topbar, .rail { position: static !important; } .rail { height: auto !important; }"


def screenshot(page: Page, name: str) -> None:
    global shot_number
    shot_number += 1
    path = EVIDENCE / f"{shot_number:02d}-{name}.png"
    page.screenshot(path=str(path), full_page=True, style=UNSTICK)
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


def badge_reads(page: Page, what: str, selector: str, label: str, timeout: float = 90) -> None:
    """Wait until the element `selector` (a card's state badge, the Egress
    line) reads `label`: the card's own state, not a rule's line that
    happens to carry the same word."""
    t0 = time.monotonic()
    reloaded = False
    while True:
        found = page.locator(selector)
        texts = [t.strip() for t in found.all_inner_texts()]
        if len(texts) == 1 and label.lower() in texts[0].lower():
            note(f"ok after {time.monotonic() - t0:.0f}s: {what} reads {texts[0]!r}")
            return
        if not reloaded and time.monotonic() - t0 > timeout / 2:
            page.reload(wait_until="networkidle")
            reloaded = True
        if time.monotonic() - t0 > timeout:
            screenshot(page, "badge")
            fail(f"{what} ({selector}) reads {texts}, expected one reading {label!r}")
        page.wait_for_timeout(2000)


ASP_BADGE = "article.asp-state-card .asp-state-head .asp-state"
GUARDRAIL_BADGE = "article.guardrail-card .asp-state-head .asp-state"
EGRESS_LINE = "article.guardrail-card p.guardrail-egress"


def click(page: Page, label: str, *, within: str = "body", exact: bool = True) -> None:
    button = page.locator(within).get_by_role("button", name=label, exact=exact)
    if button.count() != 1:
        screenshot(page, "button")
        fail(f"{button.count()} buttons {label!r} within {within}, expected one")
    button.scroll_into_view_if_needed()
    button.click()
    note(f"clicked: {label}")


def row_button(page: Page, item: str, label: str) -> None:
    """Click `label` on the guardrail row whose item is `item`."""
    row = page.locator("article.guardrail-card tr", has=page.locator(f'code:text-is("{item}")'))
    if row.count() != 1:
        screenshot(page, "row")
        fail(f"{row.count()} guardrail rows {item!r}, expected one")
    click(page, label, within=f'article.guardrail-card tr:has(code:text-is("{item}"))')


def settled(newest: str, still: Callable[[], str | None]) -> str:
    """The ASP a presenter locks: the file list can still grow while the
    agent's first calls import (stack_acceptance.py's settle), so wait until
    two scan intervals (60 s, plus the scan itself) pass with no newer ASP."""
    for _ in range(5):
        time.sleep(130)
        if demo_asps()[0]["asp_id"] == newest:
            return newest
        newest = wait_for("the newest ASP still has what the runbook names", still, 60)
    fail("the agent's ASP was still changing after five scan intervals")
    return newest


def lock(page: Page) -> None:
    """A2: lock the newest ASP, and see it ALIGNED."""
    page.reload(wait_until="networkidle")
    click(page, "Lock this as your alignment baseline")
    def aligned() -> bool:
        asps = demo_asps()
        return api(f"/api/asps/{asps[0]['asp_id']}/state").get("state") == "ALIGNED"
    wait_for("the newest ASP is ALIGNED with the locked baseline", aligned, 60)
    badge_reads(page, "the ASP card", ASP_BADGE, "Aligned")
    page_shows(page, "ALIGNED · v1.0 (active)", "v1.0", "active")


def drift(**replace: str) -> None:
    """A3: start a listener on 9000, and see the next scan drift."""
    seen = {a["asp_id"] for a in demo_asps()}
    run_block("A3", 0, contains="http.server 9000", replace=replace)

    def drifted() -> dict | None:
        for asp in demo_asps():
            if asp["asp_id"] in seen:
                continue
            state = api(f"/api/asps/{asp['asp_id']}/state")
            names = [c.get("name") for c in (state.get("drift") or {}).get("changes") or []]
            if state.get("state") == "DRIFT_DETECTED" and "observed_listeners" in names:
                return {"asp_id": asp["asp_id"], "changes": names}
        return None
    found = wait_for("the next scan shows DRIFT DETECTED with observed_listeners", drifted)
    note(f"      changes: {found['changes']}")
    unexpected = set(found["changes"]) - {"observed_listeners", "observed_file_access"}
    if unexpected:
        fail(f"the runbook names observed_listeners and observed_file_access; the drift also has {sorted(unexpected)}")


def start_page(playwright: Any) -> tuple[Any, Page]:
    browser = playwright.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 1000}, accept_downloads=True)
    page.goto(BASE + "/", wait_until="networkidle")
    return browser, page


def main() -> int:
    if PART not in ("A", "C"):
        fail(f"WALK_PART is A or C, not {PART!r}")
    result = walk_c() if PART == "C" else walk_a()
    say("Done")
    note(f"Part {PART} walked in {time.monotonic() - started:.0f}s")
    timed("the whole walk", started)
    return result


# ---- Part A ------------------------------------------------------------------

def walk_a() -> int:
    global TOKEN
    say("A0. Start clean")
    run_block("A0", 0, contains="docker compose down -v && docker compose up -d")
    run_block("A0", 1, contains="docker compose ps")
    wait_for("RailDash is up", lambda: api("/webhook/health"), 300)
    TOKEN = page_token()
    if not TOKEN:
        fail("the dashboard page carries no raildash-token")

    with sync_playwright() as playwright:
        browser, page = start_page(playwright)

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
        newest = settled(newest, second_asp)
        page_shows(page, "the interaction log, the ASP panel and the observed data action",
                   "/v1/demo", "/v1/demo/other", "/mcp", "Agent Security Profile alignment",
                   "Observed security profile", f"{TOOL}read_doc")
        screenshot(page, "a1-what-you-see")

        say("A2. Lock the baseline")
        lock(page)
        note(f"      locked on {newest}'s card")
        screenshot(page, "a2-aligned")

        say("A3. Drift")
        drift()
        badge_reads(page, "the ASP card", ASP_BADGE, "Drift detected")
        page_shows(page, "observed_listeners among the drift", "observed_listeners")
        screenshot(page, "a3-drift")

        say("A4. Data Guardrail")
        proposal = wait_for("a guardrail is proposed", lambda: guardrail()["proposal"], 60)
        would_be = {v["item"] for v in proposal["would_be_violations"]}
        note(f"      would be violations: {sorted(would_be)}")
        if would_be != {"tcp/127.0.0.1/8443"}:
            fail(f"the runbook names one would-be violation, tcp/127.0.0.1/8443; the proposal has {sorted(would_be)}")
        blocked = [b["tool"] for b in proposal.get("data_actions_blocked") or []]
        if f"{TOOL}upload_file" not in blocked:
            fail(f"the runbook says upload_file is blocked until allowed; blocked: {blocked}")
        page_shows(page, "the proposal", "Adopt a guardrail for this agent?", "Uploads",
                   "Saved files", "__pycache__", "Data actions allowed", "read_doc: read",
                   "upload_file", "tcp/127.0.0.1/8443")
        screenshot(page, "a4-proposal")
        click(page, "Adopt", within="section.guardrail-proposal")
        detail = rows_are("Adopt: g1, Violated by 9000 and 8443 under Service ports", {
            ("service_ports", "tcp/127.0.0.1/9000"), ("service_ports", "tcp/127.0.0.1/8443")})
        if detail["active"]["guardrail"]["version"] != "g1":
            fail(f"Adopt made {detail['active']['guardrail']['version']}, the runbook says g1")
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Violated")
        page_shows(page, "Allow all 2", "Allow all 2")
        screenshot(page, "a4-violated")
        click(page, "Allow all 2")
        wait_for("Allow all 2 makes g2", lambda: guardrail()["active"]["guardrail"]["version"] == "g2", 60)
        rows_are("HELD within a minute", set(), state="held")
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Held")
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
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Violated")
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
        badge_reads(page, "the Egress line", EGRESS_LINE, "Egress: Open")
        click(page, "Require containment")
        detail = rows_are("Require containment: g3, egress containment violated",
                          three | {not_offered, ("egress_containment", "open")})
        if detail["active"]["guardrail"]["version"] != "g3":
            fail(f"Require containment made {detail['active']['guardrail']['version']}, the runbook says g3")
        page_shows(page, "egress containment violated", "Egress containment")
        screenshot(page, "a7-egress")
        browser.close()
    return 0

# ---- Part C ------------------------------------------------------------------

SANDBOX_BADGE_WORDS = ("Contained", "OpenShell enforces an allow-list")
EPHEMERAL = {("service_ports", "tcp/127.0.0.1/ephemeral"), ("service_ports", "udp/127.0.0.1/ephemeral")}


def policy_revisions(out: str) -> dict[str, str]:
    """`openshell policy list`'s rows: revision -> status."""
    rows = {}
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].isdigit():
            rows[fields[0]] = fields[2]
    return rows


def loaded(out: str) -> str:
    """The revision a presenter notes as N: the first row whose status is
    Loaded, as stack-acceptance.sh reads it."""
    found = [rev for rev, status in policy_revisions(out).items() if status == "Loaded"]
    if not found:
        fail(f"policy list shows no Loaded revision: {policy_revisions(out)}")
    return found[0]


def sandbox_policy() -> str:
    result = subprocess.run(["openshell", "sandbox", "get", "my-agent", "--policy-only"], env=SHELL_ENV,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        fail(f"openshell sandbox get my-agent --policy-only: exit {result.returncode}: {result.stdout}")
    return ANSI.sub("", result.stdout)


def walk_c() -> int:
    global TOKEN
    home = Path.home()

    say("C1. Install OpenShell")
    note("      (tests/openshell/install.sh installed the pinned .deb and ran C1's second block's steps, "
         "as the runbook says CI does)")
    run_block("C1", 0, contains="enable-linger")
    out = run_block("C1", 2, contains="openshell status")
    if "Connected" not in out:
        fail("the runbook says openshell status reads Status: Connected")

    say("C2. Start clean")
    # "Fine to run when there is nothing to delete": kept going either way,
    # and the transcript shows what a fresh host prints.
    run_block("C2", 0, contains="openshell sandbox delete my-agent", check=False)
    run_block("C2", 1, contains="COMPOSE_PROFILES=openshell docker compose down -v")

    say("C3. Build the sandbox image")
    run_block("C3", 0, contains="docker build -t datrail-openshell-agent:local")

    say("C4. Create the sandbox")
    scripts = part_blocks("C", "sh").get("C4") or []
    if len(scripts) != 1 or "/sandbox/outbound" not in scripts[0]:
        fail(f"the runbook's C4 has {len(scripts)} sh block(s); the walk saves one, the agent's loop, as ~/agent-c.sh")
    (home / "agent-c.sh").write_text(scripts[0])
    note("      saved C4's sh block as ~/agent-c.sh")
    run_block("C4", 0, contains="openshell sandbox create --name my-agent")
    t0 = time.monotonic()
    while True:
        out = run_block("C4", 1, contains="openshell sandbox list")
        if any(re.search(r"\bmy-agent\b", line) and "Ready" in line for line in out.splitlines()):
            break
        if time.monotonic() - t0 > 120:
            fail("openshell sandbox list doesn't show my-agent Ready within 2 minutes")
        time.sleep(5)

    say("C5. Point the stack at the sandbox")
    run_block("C5", 0, contains="COMPOSE_PROFILES=openshell AGENT_CONTAINER=openshell:my-agent docker compose up -d")
    names = run_block("C5", 1, contains="label=openshell.ai/sandbox-name=my-agent").split()
    if len(names) != 1 or not names[0].startswith("openshell-"):
        fail(f"C5's lookup should print one openshell-… container, printed {names}")
    SHELL_ENV["A"] = names[0]
    services = subprocess.run(
        ["docker", "compose", "ps", "--status", "running", "--format", "{{.Service}}"], cwd=CHECKOUT,
        env={**SHELL_ENV, "COMPOSE_PROFILES": "openshell"}, text=True, stdout=subprocess.PIPE).stdout.split()
    note(f"      running services: {sorted(services)}")
    if len(services) != 6 or "openshell-collector" not in services or "demo-agent" in services:
        fail("the runbook says six services Up, openshell-collector among them, no demo-agent")
    wait_for("RailDash is up", lambda: api("/webhook/health"), 300)
    TOKEN = page_token()
    if not TOKEN:
        fail("the dashboard page carries no raildash-token")

    with sync_playwright() as playwright:
        browser, page = start_page(playwright)

        say("C6. What is different from Part A")

        def second_asp() -> str | None:
            asps = demo_asps()
            if len(asps) < 2:
                return None
            newest = asps[0]["asp_id"]
            files = {f.get("path") for f in answered(newest, "observed_file_access")}
            return newest if DEMO_SCRIPT in files and answered(newest, "observed_listeners") else None
        newest = wait_for("a second ASP of my-agent, with demo_client.py read", second_asp, 300)
        newest = settled(newest, second_asp)
        listeners = answered(newest, "observed_listeners")
        note(f"      observed_listeners: {json.dumps(listeners)}")
        ports = sorted(str(row.get("port")) for row in listeners)
        if ports != ["53", "53", "8443"] or not all("openshell-sandb" in json.dumps(row) for row in listeners) \
                or sum("127.0.0.53" in json.dumps(row) for row in listeners) != 2:
            fail("the runbook says three listeners, all openshell-sandb: 127.0.0.1:8443 and 127.0.0.53:53 tcp and udp")
        page_shows(page, "the agent named my-agent", "my-agent")
        screenshot(page, "c6-listeners")

        say("C7. Lock, drift, guardrail")
        lock(page)
        # C6's Egress line is on the guardrail card, which a lock brings.
        badge_reads(page, "the Egress line", EGRESS_LINE, SANDBOX_BADGE_WORDS[0])
        page_shows(page, "Contained, enforced by OpenShell", *SANDBOX_BADGE_WORDS)
        screenshot(page, "c7-contained")
        page_shows(page, "api.github.com:443 on the Egress line, read by the collector",
                   "api.github.com:443", "read by the collector")
        run_block("C7", 0, contains="--policy-only > ~/my-agent-policy.yaml")
        if "filesystem_policy" not in (home / "my-agent-policy.yaml").read_text():
            fail("~/my-agent-policy.yaml carries no filesystem_policy, which C10's export keeps")
        label = "Import a newer policy"
        if page.get_by_role("button", name=label, exact=True).count() != 1:
            label = "Import OpenShell policy"
        with page.expect_file_chooser() as chooser:
            click(page, label)
        chooser.value.set_files(str(home / "my-agent-policy.yaml"))
        page_shows(page, "the import", "Imported 1 endpoint")
        def imported() -> bool:
            policy = guardrail().get("openshell_policy")
            return bool(policy) and policy.get("source") != "collector"
        wait_for("RailDash holds the imported policy", imported, 60)
        screenshot(page, "c7-imported")
        drift(**{"datrail-demo-agent": "$A"})
        badge_reads(page, "the ASP card", ASP_BADGE, "Drift detected")
        proposal = wait_for("a guardrail is proposed", lambda: guardrail()["proposal"], 60)
        note(f"      would be violations: {sorted(v['item'] for v in proposal['would_be_violations'])}")
        page_shows(page, "the proposal, allowing api.github.com", "Adopt a guardrail for this agent?",
                   "api.github.com")
        screenshot(page, "c7-proposal")
        click(page, "Adopt", within="section.guardrail-proposal")
        rows_are("Adopt: Violated by 8443 and 9000 under Service ports", {
            ("service_ports", "tcp/127.0.0.1/9000"), ("service_ports", "tcp/127.0.0.1/8443")})
        page_shows(page, "Allow all 2", "Allow all 2")
        # A version is in force now, which is when RailDash offers Require
        # containment to one that doesn't require it.
        if page.get_by_role("button", name="Require containment", exact=True).count():
            fail("the runbook says there is no Require containment click in a sandbox")
        screenshot(page, "c7-violated")
        click(page, "Allow all 2")
        detail = rows_are("Allow all 2: HELD", set(), state="held")
        containment = (detail["rules"].get("egress_containment") or {}).get("state")
        if containment != "held":
            fail(f"the runbook says egress containment is held from the start: {containment}")
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Held")
        screenshot(page, "c7-held")

        say("C8. A call that leaves the sandbox")
        run_block("C8", 0, contains="touch /sandbox/outbound")
        wait_for("GET api.github.com /zen with a status code in the Interaction log", lambda: [
            r for r in api("/api/interactions?limit=500")["items"]
            if "api.github.com" in (r.get("host") or "") and r.get("path") == "/zen"
            and r.get("method") == "GET" and r.get("status_code")], 120)
        page_shows(page, "the GET to /zen", "/zen")
        rows_are("Violated: the trigger file and the supervisor's loopback sockets",
                 {("saved_files", "/sandbox/outbound")} | EPHEMERAL)
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Violated")
        screenshot(page, "c8-violated")
        row_button(page, "/sandbox/outbound", "Allow this")
        rows_are("Allow this on the saved file", EPHEMERAL)
        page_shows(page, "Allow all 2", "Allow all 2")
        click(page, "Allow all 2")
        rows_are("Allow all 2: HELD again", set(), state="held")
        badge_reads(page, "the guardrail card", GUARDRAIL_BADGE, "Held")
        screenshot(page, "c8-held")

        say("C9. What OpenShell blocked")
        run_block("C9", 0, contains="touch /sandbox/post")

        def blocked() -> list[dict]:
            groups = (guardrail().get("openshell_denials") or {}).get("groups") or []
            return [g for g in groups if g.get("host") == "api.github.com" and g.get("port") == 443
                    and any("POST" in r and "/markdown" in r for r in g.get("requests") or [])]
        found = wait_for("OpenShell's denial of POST /markdown, carried by the collector", blocked)
        note(f"      denial: {json.dumps(found)}")
        if not any("not permitted by policy" in reason for g in found for reason in g.get("reasons") or []):
            fail("the runbook quotes OpenShell's reason, `not permitted by policy`")
        wait_for("POST api.github.com /markdown answered 403 in the Interaction log", lambda: [
            r for r in api("/api/interactions?limit=500")["items"]
            if "api.github.com" in (r.get("host") or "") and r.get("path") == "/markdown"
            and r.get("method") == "POST" and r.get("status_code") == 403], 60)
        page_shows(page, "Blocked by OpenShell", "Blocked by OpenShell", "api.github.com:443",
                   "/markdown", "not permitted by policy")
        detail = rows_are("only the trigger file counts", {("saved_files", "/sandbox/post")})
        if any(r["rule"] == "uploads" and "api.github.com" in r["item"] for r in detail["rows"]):
            fail("the runbook says no Uploads row appears for api.github.com")
        screenshot(page, "c9-blocked")
        row_button(page, "/sandbox/post", "Allow this")
        rows_are("Allow this on the saved file: HELD", set(), state="held")
        run_block("C9", 1, contains="rm -f /sandbox/post")

        say("C10. Enforce the guardrail with OpenShell")
        version = guardrail()["active"]["guardrail"]["version"]
        with page.expect_download() as download:
            click(page, "Download as OpenShell policy")
        name = download.value.suggested_filename
        if name != f"openshell-policy-{version}.yaml":
            fail(f"the runbook says the download is openshell-policy-<version>.yaml; it is {name} at {version}")
        saved = home / "Downloads" / name
        saved.parent.mkdir(exist_ok=True)
        download.value.save_as(str(saved))
        export = saved.read_text()
        header = "\n".join(line for line in export.splitlines() if line.startswith("#")).lower()
        note(f"      the export's header:\n{header}")
        for word in ("127.0.0.1", "roll"):
            if word not in header:
                fail(f"the runbook says the header comment covers {word!r}")
        for section in ("filesystem_policy:", "landlock:", "process:", "api.github.com",
                        "enforcement: audit", "/usr/local/bin/my-agent-bin"):
            if section not in export:
                fail(f"the runbook says the export carries {section!r}")
        screenshot(page, "c10-download")
        before = loaded(run_block("C10", 0, contains="openshell policy list my-agent"))
        run_block("C10", 1, contains="openshell policy set my-agent --policy",
                  replace={"<version>": version})
        after = loaded(run_block("C10", 0, contains="openshell policy list my-agent"))
        if after == before:
            fail(f"policy set left revision {before} Loaded")
        policy = sandbox_policy()
        if "raildash_api_github_com" not in policy or "github_api:" in policy:
            fail("the runbook says the sandbox's policy has raildash_api_github_com where github_api was")
        wait_for(f"the collector posts revision {after}", lambda: str(
            (guardrail().get("openshell_policy") or {}).get("revision")) == after)
        page_shows(page, f"revision {after}, read by the collector", f"revision {after},", timeout=SCAN_WAIT)
        screenshot(page, "c10-applied")
        run_block("C10", 2, contains="--base --output json | jq -e .policy > before.json",
                  replace={"--rev N": f"--rev {before}"})
        run_block("C10", 3, contains="openshell policy set my-agent --policy before.json --wait")
        policy = sandbox_policy()
        if "github_api:" not in policy or "raildash_" in policy:
            fail(f"the rollback to revision {before} should bring github_api back")
        note(f"      rolled back to revision {before}'s policy")
        browser.close()

    say("C11. Clean up")
    run_block("C11", 0, contains="openshell sandbox delete my-agent")
    run_block("C11", 1, contains="COMPOSE_PROFILES=openshell docker compose down -v")
    return 0


if __name__ == "__main__":
    sys.exit(main())
