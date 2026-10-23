# The demo agent as an OpenShell sandbox image (DR-206): RailMon's image for
# its Python and demo scripts, plus what OpenShell asks of an image it runs:
# a non-root user and a /sandbox directory that user can write. The image's
# CMD is ignored; the command comes from `openshell sandbox create -- ...`.
ARG BASE=datrail-railmon:local
FROM ${BASE}
# The agent's own process name, as the own-agent job gives it. /data is
# where the walk's saved_files step writes.
RUN cp /usr/local/bin/python3 /usr/local/bin/my-agent-bin \
    && groupadd --gid 1500 agent && useradd --uid 1500 --gid agent --create-home agent \
    && install -d -o agent -g agent /sandbox /data
# Compose labelled the RailMon image with its project and service, and a
# container inherits its image's labels, so RailDash would know the agent as
# that service. A user's own image has none; blanked as the own-agent job does.
LABEL com.docker.compose.project="" com.docker.compose.service=""
# The demo's MCP server, declared as docker-compose.yml's demo-agent does
# (DR-237): the scanner reads it from the container's environment.
ENV AGENT_MCP_NAME=demo AGENT_MCP_URL=https://127.0.0.1:8443/mcp
WORKDIR /sandbox
USER agent
