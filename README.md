# datRail

**Intent-aligned guardrails for AI agents.**

The datRail project is building tools that can learn your AI agents' resource, data, and API baselines to automatically enforce runtime guardrails against unintended behavior.

## Why datRail?

As AI agents gain autonomous access to local file systems, personal/proprietary data via protocols like MCP, and third-party APIs, traditional static security rules quickly fall short. Agents are non-deterministic by design—predicting every API call, token threshold, or file touch in advance is nearly impossible without crippling their functionality. The datRail project solves this by introducing profile-driven runtime protection: it monitors passively your agent in a control/test run to build a precise baseline of its resource usage and data boundaries, called security profile. Such a security profile is then used to detect deviations during agent runtime. By turning observed behavior into enforceable guardrails, datRail lets developers and power users deploy agentic workflows without giving agents a blank check to their critical data and infrastructure.

## Installation

See **[INSTALL.md](INSTALL.md)** for the full install guide — it covers the local bundle (RailMon + RailDash), prerequisites, the platform support matrix, verification, and troubleshooting.

## Components

- **RailMon** — a CLI daemon that taps live agent traffic at the kernel level (eBPF) and records interactions.
- **RailDash** — a local dashboard that imports RailMon's capture and shows what the agent actually did.
