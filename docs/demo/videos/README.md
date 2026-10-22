# The four videos

Short, slow-paced, each under two minutes, recorded on one machine with the quick-start stack. The commands are the demo agent's; the videos are meant to run on a real OpenClaw agent, so each step will be redone as a prompt to that agent once the real-agent drift fix (raildash#92) is verified. One script per video, same structure: what the viewer sees first, the commands typed, what changes on screen, the one sentence that explains it.

| # | Video | Shows | Script |
| --- | --- | --- | --- |
| 1 | Introduction | what datRail is, the stack coming up, the first Agent Security Profile | [01-intro.md](01-intro.md) |
| 2 | Port drift | baseline locked, the agent opens a port, drift at the next scan, the guardrail adopted and held | [02-port-drift.md](02-port-drift.md) |
| 3 | Tool misuse | three MCP tool calls classified as upload, unknown and unreadable; a saved file and an upload violation | [03-tool-misuse.md](03-tool-misuse.md) |
| 4 | Egress containment | the same agent on an open network reads Open and violates Require containment; in an OpenShell sandbox it reads Contained | [04-egress.md](04-egress.md) |
