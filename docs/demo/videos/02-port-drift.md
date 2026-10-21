# Video 2: Port drift and the guardrail (draft)

Target length: under 2 minutes.

1. Two ASPs are in. Click **Lock this as your alignment baseline** → ALIGNED v1.0.
2. Terminal: `docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1`
3. Within 20 s: DRIFT DETECTED, `observed_listeners` gained 9000. Expand Before / After.
4. Scroll to Data Guardrail: **Adopt** → g1 VIOLATED (9000, 8443, 127.0.0.1). **Allow all 2**, **Allow this** → HELD.
5. One sentence: "The baseline is what it normally does. The guardrail turns that into rules, and anything unseen needs a person."

Runbook: Part A, steps A2 to A4.
