"""RailDash's API, read the way a user's dashboard reads it: datRail's
verdicts (guardrail rows, the Interaction log) and the few writes a user
makes to onboard an agent (lock a baseline, adopt the proposed guardrail,
allow rows). The suite changes nothing else in datRail (design §2,
non-goals).
"""
from __future__ import annotations

import json
import re
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.error import URLError
from urllib.request import Request, urlopen

TRANSIENT = (URLError, OSError, KeyError, ValueError, IndexError, TypeError)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class RailDash:
    def __init__(self, base: str, ours: Callable[[dict], bool], token: str = "") -> None:
        self.base = base.rstrip("/")
        self.ours = ours
        self.token = token
        self._ref: str | None = None

    def call(self, path: str, body: dict | None = None) -> Any:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["X-RailDash-Token"] = self.token
        data = json.dumps(body).encode() if body is not None else None
        request = Request(self.base + path, data=data, headers=headers,
                          method="POST" if body is not None else "GET")
        with urlopen(request, timeout=30) as response:
            return json.load(response)

    def page_token(self) -> str:
        """The local write token the dashboard page carries, as a browser
        session gets it."""
        with urlopen(self.base + "/", timeout=10) as response:
            found = re.search(r'<meta name="raildash-token" content="([^"]+)"',
                              response.read().decode())
        return found.group(1) if found else ""

    # -- reads ---------------------------------------------------------------

    def asps(self) -> list[dict]:
        """The agent's ASPs, newest first."""
        return [a for a in self.call("/api/asps?limit=500")["items"]
                if self.ours(a.get("agent_identity") or {})]

    def attribute(self, asp_id: str, name: str) -> list:
        attribute = self.call(f"/api/asps/{asp_id}/bundle")["attributes"][name]
        return (attribute.get("value") or []) if attribute.get("status") in ("ANSWERED", "PARTIAL") else []

    def agent_ref(self) -> str:
        if self._ref is None:
            agents = [a for a in self.call("/api/guardrails") if self.ours(a.get("agent_identity") or {})]
            if len(agents) != 1:
                raise KeyError(f"{len(agents)} guardrails listed for the agent")
            self._ref = agents[0]["agent_ref"]
        return self._ref

    def guardrail(self) -> dict:
        return self.call(f"/api/guardrails/{self.agent_ref()}")

    def interactions(self, pages: int = 20) -> list[dict]:
        items: list[dict] = []
        for page in range(pages):
            got = self.call(f"/api/interactions?limit=500&offset={page * 500}")["items"]
            items += got
            if len(got) < 500:
                break
        return items

    # -- a user's onboarding writes -----------------------------------------

    def lock(self, asp_id: str, version: str) -> str:
        made = self.call(f"/api/asps/{asp_id}/lock", {"version": version})
        self.call(f"/api/alignments/{made['alignment_version_id']}/switch", {})
        return made["alignment_version_id"]

    def adopt(self) -> dict:
        proposal = self.guardrail()["proposal"]
        if not proposal or not proposal.get("guardrail"):
            raise KeyError("no guardrail proposed")
        return self.call(f"/api/alignments/{proposal['alignment_version_id']}/guardrail", {})

    def allow_rows(self, row_ids: list[int]) -> dict:
        return self.call(f"/api/guardrails/{self.agent_ref()}/allow-rows", {"row_ids": row_ids})


def wait_for(what: str, check: Callable[[], Any], timeout: float, every: float = 2.0,
             log: Callable[[str], None] = print) -> Any:
    t0 = time.monotonic()
    last: Any = None
    while True:
        try:
            result = check()
        except TRANSIENT as error:
            result, last = None, error
        if result:
            log(f"ok after {time.monotonic() - t0:.0f}s: {what}")
            return result
        if time.monotonic() - t0 > timeout:
            raise TimeoutError(f"not within {timeout:.0f}s: {what} (last error: {last})")
        time.sleep(every)


ROW_FIELDS = ("rule", "item", "count", "counts", "first_seen", "last_seen", "acknowledged")


class Snapshots(threading.Thread):
    """Reads the guardrail's rows every `every` seconds into a JSONL file,
    until stopped: the scorer's view of when each row appeared."""

    def __init__(self, dash: RailDash, path: Path, every: float = 2.0) -> None:
        super().__init__(daemon=True)
        self.dash, self.path, self.every = dash, path, every
        self._halt = threading.Event()
        self.errors = 0

    def run(self) -> None:
        with self.path.open("a") as out:
            while not self._halt.is_set():
                at = now()
                try:
                    detail = self.dash.guardrail()
                except TRANSIENT:
                    self.errors += 1
                else:
                    rows = [{k: r.get(k) for k in ROW_FIELDS} for r in detail["rows"]]
                    out.write(json.dumps({"at": at, "state": detail.get("state"), "rows": rows}) + "\n")
                    out.flush()
                self._halt.wait(self.every)

    def stop(self) -> None:
        self._halt.set()
        self.join(timeout=60)
