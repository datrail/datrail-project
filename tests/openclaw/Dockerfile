# A real OpenClaw agent for the openclaw job (tests/openclaw/acceptance.sh):
# the published npm package, pinned, on the Node it asks for. The same image
# serves the stub model, from another container, with Debian's Python.
FROM node:26-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*
ARG OPENCLAW_VERSION=2026.10.8
RUN npm install -g --no-audit --no-fund "openclaw@${OPENCLAW_VERSION}" \
 && openclaw --version
COPY model_stub.py agent-loop.sh openclaw.json openclaw-gateway.json /opt/openclaw-ci/
USER node
WORKDIR /home/node
CMD ["/opt/openclaw-ci/agent-loop.sh"]
