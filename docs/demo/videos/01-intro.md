# Video 1: Introduction (draft)

Target length: under 2 minutes.

## Opening slides (about 30 s)
- What datRail is: RailMon watches an AI agent from outside (kernel probes, no agent changes); RailDash shows what it does and holds it to a baseline.
- The three things a viewer will see: a profile that appears on its own, drift when the agent changes behaviour, a guardrail that flags what the baseline never allowed.

## Screen (about 80 s)
1. `git clone https://github.com/datrail/datrail-project && cd datrail-project && docker compose up -d` (the first start pulls the images in under a minute).
2. Open http://127.0.0.1:8000: interactions arriving, the first ASP within a minute. Click **Inspect evidence**: listeners, files, hosts.
3. One sentence: "Nothing here was configured by hand. RailMon watched the agent and wrote this down."

Runbook: Part A, steps A0 to A1.
