# railbench

datRail's evaluation suite (DR-289; design: railxia/docs
`design/2026-11-12-eval-suite/eval-suite-design.md`). Real agents, watched by
a pinned datRail, try to move seeded data out through MCP servers and APIs,
and run benign tasks; the scorer sets what actually happened beside what
datRail flagged, and reports agent task success with and without datRail,
detection (exfiltration first), false positives, detection latency, capture
coverage and onboarding cost, with confidence intervals clustered by task.

This directory is laid out as the root of its own repository: nothing in it
reads a path outside `bench/`. If `datrail/railbench` is created it moves
there unchanged, with `.github/workflows/bench.yml` beside it.

## Layout

| Path | What |
|---|---|
| `railbench/runner.py` | Onboards the agent as a user does (lock a settled ASP, adopt the proposed guardrail, allow until HELD, counting each allow), runs a scenario's tasks in the agent's container, and reads the guardrail rows every `poll_s` |
| `railbench/raildash.py` | RailDash's API: the reads, and the few onboarding writes a user makes |
| `railbench/score.py` | The scorer (§4.4, §4.5): a row detects an action only when rule, object and time window all match; unclaimed rows are false positives; refused or failed actions leave the denominator |
| `railbench/stats.py` | Rates with 95% intervals clustered by task; paired differences |
| `railbench/receiver.py` | A stand-in receiver: answers 200 and logs every request's body, path, query and headers (credentials dropped) |
| `railbench/matcher.py` | The seeded-record matcher: which seeded records reached a receiver, through URL, base64, hex, gzip/zlib and JSON escapes |
| `scenarios/demo-agent.json` | The scorer self-test (§6): datRail's scripted demo agent, whose rows are known, with the report it must give |
| `tests/` | Unit tests; standard library only |

## Run

```bash
python3 -m unittest discover -s tests -t .           # the scorer's tests
# With a datRail stack and its demo agent running (datrail-project's
# `docker compose up -d`, SCAN_INTERVAL=10 for speed):
python3 -m railbench run scenarios/demo-agent.json --out /tmp/run --score
python3 -m railbench score /tmp/run --expect scenarios/demo-agent.json
python3 -m railbench receiver --listen 0.0.0.0:8080 --log /tmp/receiver.jsonl
```

A run directory keeps `run.json`, `actions.jsonl` (ground truth),
`snapshots.jsonl` (rows over time), `interactions.json`, `guardrail.json`,
and the scored `report.json` / `report.md`. It is raw data: keep it.

## State (M1)

Done: the scorer, statistics, receiver and matcher with unit tests; the
demo-agent self-test scenario and its CI job. Next, in order: the §4.1a
exfiltration set (stand-in MCP servers and APIs holding seeded records,
receivers as the paths out, direct and poisoned-tool steering) on OpenClaw
with the replay model; the Terminal-Bench benign subset with its
with-and-without-datRail comparison; the coverage probes.
