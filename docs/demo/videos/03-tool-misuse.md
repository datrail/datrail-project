# Video 3: Tool misuse and data violations (draft)

Target length: under 2 minutes. Starts from the end of video 2 (guardrail HELD).

1. `docker exec datrail-demo-agent sh -c 'mkdir -p /data && echo report > /data/report.zip'` → Saved files VIOLATED at the next scan.
2. The exfil.example POST from the runbook → Uploads and Out-of-spec calls VIOLATED.
3. The three MCP calls, a few seconds apart:
   - `demo_mcp_call.py upload_file` → DATA ACTIONS `upload_file · upload` (carrying an image)
   - `demo_mcp_call.py export_all` → `unclassified`, a minute later `not offered`
   - `demo_mcp_call.py --garbage` → `unreadable call`
4. One sentence: "Each tool call is classified from the schema the agent was given: read, upload, update, delete, execute. A tool the server never listed, or a call that is not even JSON-RPC, is flagged on its own."

Runbook: Part A, steps A5 to A6. Timing note: send the calls a few seconds after any guardrail click (the capture clock can run up to a second early).
