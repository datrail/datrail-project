# DatRail glossary

The terms DatRail's components and documentation use, and what each one
means in RailMon and RailDash today.

- [Agent Security Profile (ASP)](#agent-security-profile-asp)
- [Alignment](#alignment)
- [Baseline](#baseline)
- [Drift](#drift)
- [Evidence](#evidence)
- [Evidence bundle](#evidence-bundle)
- [Identity](#identity)
- [Interaction](#interaction)
- [Profile](#profile)

## Agent Security Profile (ASP)

What one agent was observed to have and do at one point in time, kept as an
immutable record. RailDash creates one ASP from each
[evidence bundle](#evidence-bundle) it receives, and stores the exact bytes it
received. Two copies of the same bundle are one ASP.

An ASP is not a policy and carries no score. It describes; it does not judge.
Locking an ASP makes it a [baseline](#baseline), which is what later ASPs are
compared with.

Always write "Agent Security Profile" or "ASP", not "profile" alone (which
reads as performance profiling) and not "intent".

## Alignment

Whether an agent still does what its [baseline](#baseline) says it does.
RailDash compares every new ASP with the agent's active baseline as it
arrives and gives it one state:

| State | Meaning |
| --- | --- |
| `ALIGNED` | The ASP matches the baseline. |
| `DRIFT_DETECTED` | Something differs; the result lists each changed attribute (see [drift](#drift)). |
| `NO_ACTIVE_ALIGNMENT` | The agent has no baseline yet. This is a warning, never a clean result. |
| `COMPARISON_UNAVAILABLE` | The two ASPs cannot be compared safely: a different identity, evidence bundle version or scanner rule pack, an invalid bundle, or a baseline that fails its integrity check. Neither aligned nor drifted. |

In RailDash this is the **Agent Security Profile alignment** panel.

## Baseline

The ASP an agent is compared against. In RailDash you lock an existing ASP as
a named, immutable **alignment version**, and the agent's **active
alignment** points at one of its versions. Locking never copies or changes
the ASP.

Every locked version stays available. You can switch the active alignment
back to an earlier version, or accept a drifted ASP as a new version, from the
dashboard or with `raildash asp lock` / `raildash asp switch`. Nothing is
locked automatically: a baseline always comes from a person deciding that this
is how the agent should behave.

## Drift

Runtime drift: a difference between what the agent actually uses and does
now and what its [baseline](#baseline) recorded. It is about behaviour
observed while the agent runs, such as a new destination, a newly opened
port, or a new client connecting in, and not only about changes to declared
configuration.

A drift result names each changed attribute and, behind the local write
token, shows the old and new values with their [evidence](#evidence) tier.
Lost visibility is reported, not hidden: an attribute that was observed in the
baseline but cannot be observed now is a change, never "no change".

RailDash also has **capture drift**, a separate panel that compares the
[observed profiles](#profile) of two capture sessions.

## Evidence

Each fact in an [evidence bundle](#evidence-bundle) says how it is known.
DatRail keeps four kinds of evidence apart and never merges them:

| Kind | Meaning | In the evidence bundle |
| --- | --- | --- |
| **Observed** | Seen at runtime: traffic RailMon captured, sockets the agent opened. | `tier: "observed"` |
| **Declared** | Stated by configuration the agent or its operator wrote: MCP config, `SKILL.md` files, environment, container settings. | `tier: "declared"` |
| **Attested** | Vouched for by a verifier outside the agent. | an entry in `attestations`, referenced by an attribute's `attestation_ref`. RailMon's scanner produces none yet. |
| **Unknown** | Could not be seen. | `status: "BLIND"` or `"FAILED"`, with a reason code. |

The schema also allows a third tier, `interrogated`; RailMon's scanner does
not emit it today.

Every attribute also has a status: `ANSWERED` (a value), `ABSENT` (looked
properly, genuinely not there), `TEMPLATED` (present, value set at
deployment), `PARTIAL` (incomplete, so a lower bound), `BLIND` or `FAILED`.
"Unknown" is never written as an empty value, so "we could not see it" is
never read as "there is none".

## Evidence bundle

The JSON document `railmon scan` writes for one scan of one agent (or, with a
target manifest, of several agents in one sandbox). It is the input every ASP
is made from. It carries:

- `host_id` and `sandbox_name`: which machine and container it describes;
- `collected_at` and `rule_pack_version`: when, and by which version of the
  scanner's rules;
- `attributes`: one entry per fact, each with a value, a status, an
  [evidence](#evidence) tier and, when not answered, a reason code;
- `attestations`: reserved for third-party verification.

`bundle_version: 1` describes one agent. `bundle_version: 2` is a multi-agent
collection: a shared sandbox scope plus one scope per declared agent. The
schemas are in [RailMon's `schemas/`](https://github.com/datrail/railmon/tree/master/schemas).

`railmon scan --interval N --raildash-url URL` delivers a new bundle every
N seconds to RailDash's `POST /v1/evidence-bundles`.

## Identity

Which agent an ASP belongs to, so that only ASPs of the same agent are ever
compared. RailDash takes the first of these that is complete and never
guesses from resemblance:

1. a deployment pair from the agent's environment (`RAIL_DEPLOYMENT` and
   `RAIL_NAMESPACE`);
2. its Compose project and service, together with `host_id`;
3. a local agent key the operator supplies (`railmon scan --agent-key`, or
   `?agent_key=` on delivery);
4. for a multi-agent bundle, its set of agent keys.

## Interaction

One request and its response, captured from the agent's TLS traffic by
`railmon collect` and delivered to RailDash's webhook. Interactions are what
the dashboard's capture views and the [observed profile](#profile) are built
from. Credential headers are redacted before they leave RailMon; bodies are
not.

## Profile

Short for one of two things; say which:

- **Agent Security Profile (ASP)**: see [above](#agent-security-profile-asp).
- **Observed profile**: RailDash's summary of one capture session's
  [interactions](#interaction): destinations, bytes sent per host, content
  kinds uploaded, tool calls and the files they asked to read or write
  (`GET /api/profile`). It has no score and no baseline, and is compared
  only in the capture drift panel.
