# Demo scripts and setup notes (drafts)

Working material for the datRail 0.2 demo and the four short videos. Drafts: what is here is what was run and measured, not final documentation; the user-facing install guide is [INSTALL.md](../../INSTALL.md).

| File | What it is |
| --- | --- |
| [DEMO_RUNBOOK.md](DEMO_RUNBOOK.md) | The hands-on walk, step by step with what RailDash shows and how long each step takes: Part 0 where to run it, A the demo agent, B your own agent, C an agent in an OpenShell sandbox, troubleshooting, measured timings. |
| [GCP_VM_SETUP.md](GCP_VM_SETUP.md) | A throwaway Linux VM on GCP in five commands, for hosts that cannot run the probes natively (Macs) or OpenShell. |
| [CAPABILITIES_DEMO_TABLE.md](CAPABILITIES_DEMO_TABLE.md) | The 16 capabilities delivered in 0.2, each with the command that produces its drift or violation and where the step is scripted (runbook part, CI step in `tests/stack_acceptance.py`). |
| [videos/](videos/) | One script per video: intro, port drift, tool misuse, egress containment. |

Every demo step is one the stack CI runs on every merge (`tests/stack-acceptance.sh`), so a step that works here works in CI and the other way round.
