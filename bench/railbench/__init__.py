"""railbench: datRail's evaluation suite (DR-289, railxia/docs design
`2026-11-12-eval-suite`). Real agents, watched by a pinned datRail, try to
move seeded data out through MCP servers and APIs; the scorer sets what
actually happened beside what datRail flagged.

Standard library only, so the runner needs nothing installed beside the
agents and the stack it drives.
"""

__version__ = "0.1.0.dev0"
