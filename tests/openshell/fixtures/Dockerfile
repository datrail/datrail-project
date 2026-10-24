# The smallest image OpenShell runs as a sandbox, for recording fixtures
# (DR-248): Python for the denial attempts, a non-root user and a writable
# /sandbox, which OpenShell asks of any image.
FROM python:3.13-slim
RUN groupadd --gid 1500 agent && useradd --uid 1500 --gid agent --create-home agent \
    && install -d -o agent -g agent /sandbox
COPY attempts.py /opt/attempts.py
WORKDIR /sandbox
USER agent
