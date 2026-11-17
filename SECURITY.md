# Security Policy

This repository runs the open-source DatRail stack: `docker-compose.yml`,
`install.sh` and the docs that install RailMon and RailDash next to your
agent. RailMon captures your agent's decrypted traffic and RailDash stores
and shows it, so a running stack holds data as sensitive as that traffic.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use the repository's **Security** tab to open a private vulnerability report.

Please include what an attacker can do (not only what is wrong), the commit
or the image tags you ran, the smallest reproduction you have, and whether
you have told anyone else.

## What to expect

| | |
| --- | --- |
| Acknowledgement | within 3 working days |
| First assessment | within 10 working days |
| Progress | at least every 10 working days until it closes |

We ask for **90 days** before public disclosure and will usually be much
faster. If a fix will take longer we will say so and agree a date rather than
let it lapse quietly. You will be credited unless you would rather not be.

## Scope

In scope: this repository — the compose file, `install.sh`, the setup
guides, and the defaults they give a stack (which images and tags it runs,
which ports it opens and where it binds them, what it mounts and with which
privileges).

A problem inside a component belongs to that component's policy:
[RailMon](https://github.com/datrail/railmon/blob/master/SECURITY.md) and
[RailDash](https://github.com/datrail/raildash/blob/master/SECURITY.md).
Report it there, or here if you are unsure; we will route it.

Out of scope, but tell us anyway if it looks serious: Docker, the kernel, an
agent runtime such as NVIDIA OpenShell, and anything that needs an attacker
who already has root on the host. RailMon runs privileged to load its eBPF
probes, and that is assumed.

## What the stack does and does not protect

- **RailDash listens on `127.0.0.1` only**, and it is the only port the
  stack publishes (RailMon delivers to RailDash's webhook inside the
  stack). An install step or guide that exposes either to another host by
  default is a vulnerability — report it.
- **Captured data is not sanitised.** Credential headers are stripped before
  anything leaves RailMon, but request and response bodies are kept as
  captured. Treat the stack's volumes and anything exported from RailDash
  as being as sensitive as the agent's own traffic.
- **The images are pinned to fixed published tags.** A guide that installs
  an unpinned or unverified image is a defect worth reporting.
