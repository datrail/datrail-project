# Contributing to datrail-project

This repository is DatRail's front door: it runs the open-source stack on one
machine (`docker-compose.yml`, `install.sh`), documents how to install it
against an agent you already run, and links to every component. The code
that captures and shows an agent's behaviour lives in the component
repositories:

- [RailMon](https://github.com/datrail/railmon) — scans an agent's setup and
  captures what it does at runtime;
- [RailDash](https://github.com/datrail/raildash) — the local dashboard: the
  Agent Security Profile, baselines, drift and the Data Guardrail.

A change to what is captured or shown belongs there. A change to how the stack
is installed, configured, pinned or documented belongs here.

## What a change here must keep working

People follow these files by hand and their own AI agents follow them too
(`docs/agent-install.md`), so a step that drifts from what the stack actually
does breaks an install silently.

- **Pinned images.** `docker-compose.yml` runs each component at a fixed
  published tag. Moving a tag is a deliberate change, made once the new tag
  is published, in a PR of its own.
- **Install steps that run.** Every command a guide gives is one CI runs:
  the quick start, watching your own agent, the published images, and
  `install.sh` against an agent that is already running (`stack.yml`'s jobs
  `install`, `own-agent`, `published` and `existing-agent`). A new or changed
  step comes with the test that runs it.
- **Local by default.** RailDash binds to `127.0.0.1`. Nothing here exposes
  the stack beyond the host unless the user asks for it.

## Development

```bash
make up        # start the stack from the pinned images
make test      # run tests/stack-acceptance.sh, CI's check, against a live stack
make down
```

Both need Docker with Compose v2 and a kernel with BTF, as the quick start
does.

## Sending a change

- One coherent change per pull request; the message says *why*.
- Branch from `master`, **sign off your commits** (`git commit -s`,
  [DCO](https://developercertificate.org/)), no CLA.
- CI runs the stack jobs above, plus `openshell`, `arm64` and
  `install-script`. All but `published` are required checks.
- A maintainer reviews the pull request's head commit and records the result
  as the `rail-review` status on that commit. It is a required check: a pull
  request merges only once it passes, and every new push needs a new review.
  When yours is ready, mark it ready for review or ask on the pull request.

## Reporting a vulnerability

Not here — see [SECURITY.md](SECURITY.md).
