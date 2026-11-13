"""Run a scenario against an agent watched by a running datRail, and write
a run directory the scorer reads (design §4.3).

    python3 -m railbench run scenarios/demo-agent.json --out RUN_DIR \
        [--url http://127.0.0.1:8000] [--score]

The datRail stack and the agent are already up; the runner does what a user
does to onboard it (lock the newest settled ASP, adopt the proposed
guardrail, allow what it flags until HELD, counting each allow as
onboarding cost), then runs each task in the agent's container, records
when it started and ended and how it went, and reads the guardrail rows
throughout. M1's first scenario is the scripted demo agent, whose rows are
known: the scorer self-test (§6).
"""
from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

from .raildash import RailDash, Snapshots, now, wait_for


def _identity_matcher(spec: dict):
    def ours(who: dict) -> bool:
        kind, value = who.get("kind"), who.get("value")
        if spec.get("kind") == "deployment_compose":
            return (kind == "deployment_compose" and isinstance(value, dict)
                    and value.get("service") == spec["service"]
                    and (not spec.get("project") or value.get("project") == spec["project"]))
        key = spec["value"]
        return (kind == "local_agent_key" and value == key) or (
            kind == "local_agent_keys" and isinstance(value, list) and key in value)
    return ours


def onboard(dash: RailDash, scenario: dict, log) -> dict:
    """From a fresh stack to HELD, as a user does it in the dashboard."""
    t0 = time.monotonic()
    want = scenario.get("baseline") or {}
    settle = float(want.get("settle_s", 20))

    def ready() -> str | None:
        asps = dash.asps()
        if not asps:
            return None
        newest = asps[0]["asp_id"]
        if want.get("listen_port") and want["listen_port"] not in {
                l.get("port") for l in dash.attribute(newest, "observed_listeners")}:
            return None
        if want.get("reads") and want["reads"] not in {
                f.get("path") for f in dash.attribute(newest, "observed_file_access")}:
            return None
        return newest

    # Lock only an ASP that stayed the newest for `settle` seconds, so the
    # baseline isn't taken halfway through the agent's first calls.
    for _ in range(10):
        newest = wait_for("an ASP with the agent's baseline evidence", ready, 300, log=log)
        time.sleep(settle)
        if dash.asps()[0]["asp_id"] == newest:
            break
    else:
        raise TimeoutError("the agent's evidence kept changing")
    dash.lock(newest, f"railbench-{int(time.time())}")
    log(f"locked {newest}")
    wait_for("a guardrail is proposed", lambda: dash.guardrail()["proposal"], 120, log=log)
    adopted = dash.adopt()
    log(f"adopted {adopted['guardrail']['version']}")

    allows = 0
    allowed_items: list[str] = []
    for _ in range(5):
        # The adopted version is checked at the next scans; wait until the
        # state has stopped moving before reading what it flags.
        detail = wait_for("the guardrail has a state", lambda: (
            d := dash.guardrail())["state"] in ("held", "violated") and d, 180, log=log)
        time.sleep(settle)
        detail = dash.guardrail()
        counting = [r for r in detail["rows"] if r.get("counts")]
        if detail["state"] == "held" and not counting:
            break
        if counting:
            dash.allow_rows([r["row_id"] for r in counting])
            allows += len(counting)
            allowed_items += [f"{r['rule']} {r['item']}" for r in counting]
            log(f"allowed {[(r['rule'], r['item']) for r in counting]}")
    else:
        raise TimeoutError("the guardrail did not reach HELD after five rounds of allows")
    wait_for("HELD", lambda: dash.guardrail()["state"] == "held", 180, log=log)
    return {"manual_allows": allows, "allowed": allowed_items,
            "seconds_to_held": round(time.monotonic() - t0)}


def run_task(task: dict, container: str, log) -> dict:
    started = now()
    outcome = "happened"
    output = ""
    if task.get("exec"):
        result = subprocess.run(["docker", "exec", container, *task["exec"]], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        output = result.stdout[-2000:]
        if result.returncode != 0 or (task.get("output_has") and task["output_has"] not in output):
            outcome = "failed"
    elif task.get("sleep_s"):
        time.sleep(float(task["sleep_s"]))
    ended = now()
    log(f"{task['task']}: {outcome} ({output.strip()[-200:]!r})")
    return {**{k: v for k, v in task.items() if k not in ("exec", "sleep_s", "output_has")},
            "trial": task.get("trial", 1), "started": started, "ended": ended,
            "outcome": outcome, "output": output}


def run(scenario_path: Path, out: Path, url: str, log=print) -> Path:
    scenario = json.loads(scenario_path.read_text())
    out.mkdir(parents=True, exist_ok=True)
    agent = scenario["agent"]
    dash = RailDash(url, _identity_matcher(agent["identity"]))
    wait_for("RailDash is up", lambda: dash.call("/webhook/health"), 300, log=log)
    dash.token = dash.page_token()
    onboarding = onboard(dash, scenario, log)

    snapshots = Snapshots(dash, out / "snapshots.jsonl", float(scenario.get("poll_s", 2)))
    snapshots.start()
    time.sleep(float(scenario.get("poll_s", 2)) * 2)  # the reference snapshot
    eval_started = now()
    gap = float(scenario.get("gap_s", 20))
    with (out / "actions.jsonl").open("w") as actions:
        for task in scenario["tasks"]:
            for trial in range(1, int(task.get("trials", scenario.get("trials", 1))) + 1):
                record = run_task({**task, "trial": trial}, agent["container"], log)
                actions.write(json.dumps(record) + "\n")
                actions.flush()
                time.sleep(gap)
    eval_ended = now()
    time.sleep(float(scenario.get("window_s", 120)))  # rows that come late
    snapshots.stop()
    (out / "interactions.json").write_text(json.dumps(dash.interactions(), indent=1))
    (out / "guardrail.json").write_text(json.dumps(dash.guardrail(), indent=1))
    (out / "run.json").write_text(json.dumps({
        "name": scenario["name"], "agent": agent.get("name"), "runtime": agent.get("runtime"),
        "environment": scenario.get("environment", "docker"),
        "datrail": scenario.get("datrail") or {}, "runner": "railbench",
        "poll_s": float(scenario.get("poll_s", 2)), "window_s": float(scenario.get("window_s", 120)),
        "eval_started": eval_started, "eval_ended": eval_ended,
        "onboarding": onboarding, "snapshot_errors": snapshots.errors,
    }, indent=1))
    return out
