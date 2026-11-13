"""railbench's command line: run, score, selftest, receiver."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import receiver, runner, score


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="railbench")
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="run a scenario against a running datRail and agent")
    p_run.add_argument("scenario", type=Path)
    p_run.add_argument("--out", type=Path, required=True)
    p_run.add_argument("--url", default=os.environ.get("RAILDASH_URL", "http://127.0.0.1:8000"))
    p_run.add_argument("--score", action="store_true", help="score the run when it ends")

    p_score = sub.add_parser("score", help="score a run directory")
    p_score.add_argument("run_dir", type=Path)
    p_score.add_argument("--expect", type=Path,
                         help="a scenario with `expected`: exit 1 when the report differs (the self-test)")

    p_recv = sub.add_parser("receiver", help="a stand-in receiver that logs what arrives")
    p_recv.add_argument("--listen", default="127.0.0.1:8080")
    p_recv.add_argument("--log", type=Path, required=True)
    p_recv.add_argument("--tls-cert", type=Path)
    p_recv.add_argument("--tls-key", type=Path)

    args = parser.parse_args(argv)
    if args.command == "receiver":
        host, _, port = args.listen.rpartition(":")
        server = receiver.Receiver((host or "0.0.0.0", int(port)), args.log, args.tls_cert, args.tls_key)
        print(f"receiving on {args.listen}, logging to {args.log}", flush=True)
        server.serve_forever()
        return 0
    if args.command == "run":
        run_dir = runner.run(args.scenario, args.out, args.url)
        if not args.score:
            return 0
        return _score(run_dir, args.scenario)
    return _score(args.run_dir, args.expect)


def _score(run_dir: Path, expect: Path | None) -> int:
    report = score.score(run_dir)
    (run_dir / "report.json").write_text(json.dumps(report, indent=1, default=str))
    (run_dir / "report.md").write_text(score.render_markdown(report))
    print(score.render_markdown(report))
    if expect is None:
        return 0
    expected = json.loads(expect.read_text()).get("expected") or {}
    problems = score.check_expected(report, expected)
    for problem in problems:
        print(f"SELF-TEST FAIL: {problem}", file=sys.stderr)
    if not problems:
        print("self-test: the report matches the scenario's expected rows")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
