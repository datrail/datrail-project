# Video 4: Egress containment (draft)

Target length: under 2 minutes. Needs a Linux host for the OpenShell half (the GCP VM).

1. Demo agent on an ordinary Docker network: the card's Egress reads **Open**. Click **Require containment** → g4, Egress containment VIOLATED.
2. Cut to the OpenShell sandbox (runbook Part C): the same agent script in a sandbox. Egress reads **Contained: it should not reach outside hosts itself; OpenShell enforces an allow-list**; the proposal already requires containment and the rule is held.
3. `docker exec $A touch /sandbox/outbound` → within 30 s the Interaction log shows `GET api.github.com /zen`, the one host the policy allows, made through OpenShell's supervisor.
4. One sentence: "datRail reads from Docker whether the agent can reach the world at all. In a sandbox it cannot, except where the policy says so, and the collector still sees what it sends."

Runbook: Part A step A7, Part C steps C4 to C8.
