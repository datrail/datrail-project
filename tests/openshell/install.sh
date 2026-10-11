#!/usr/bin/env bash
# Install a pinned OpenShell on a disposable CI host and start its local
# gateway with the Docker driver, the steps of OpenShell's own install.sh
# for a Debian host, against a checksum pinned here (DR-206). Not for a
# user's machine: there, OpenShell's install.sh is the way.
set -euo pipefail
OPENSHELL_VERSION=0.1.3
OPENSHELL_DEB_SHA256=64000b75aaf7d23763ad43aef6d9d6386325cba7bb636a64539a13ce98f88108

deb="openshell_${OPENSHELL_VERSION}-1_amd64.deb"
work=$(mktemp -d)
curl -fsSL -o "$work/$deb" \
  "https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VERSION}/$deb"
echo "$OPENSHELL_DEB_SHA256  $work/$deb" | sha256sum -c -
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$work/$deb"

mkdir -p "$HOME/.config/openshell"
printf 'OPENSHELL_COMPUTE_DRIVER=docker\nOPENSHELL_TELEMETRY_ENABLED=false\n' \
  > "$HOME/.config/openshell/gateway.env"
systemctl --user daemon-reload
systemctl --user enable openshell-gateway
systemctl --user restart openshell-gateway
openshell gateway add https://127.0.0.1:17670 --local --name openshell
for _ in $(seq 60); do
  NO_COLOR=1 openshell status 2>/dev/null | grep -q 'Version:' && break
  sleep 2
done
NO_COLOR=1 openshell status
