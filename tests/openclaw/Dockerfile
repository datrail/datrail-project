# A real OpenClaw agent for the openclaw job (tests/openclaw/acceptance.sh):
# the published npm package, pinned, on the Node it asks for. The same image
# serves the stub model, from another container, with Debian's Python.
FROM node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
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
