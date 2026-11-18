#!/usr/bin/env bash
# A Linux VM on Google Cloud to run DatRail on, one per person. It creates the VM with
# Docker already installed, opens an SSH session with RailDash forwarded to your machine,
# and stops or deletes it. docs/setup-gcp-vm.md walks through it.
#
#   ./gcp-vm.sh create      # once: the VM, with Docker
#   ./gcp-vm.sh ssh         # each time: a session, RailDash at http://127.0.0.1:8000
#   ./gcp-vm.sh stop        # when you are done (the disk still bills while stopped)
#   ./gcp-vm.sh start       # to use it again
#   ./gcp-vm.sh delete      # when you no longer need it (it asks first)
#
# It needs only the gcloud CLI, signed in (gcloud auth login).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gcp-vm.sh COMMAND [options]

Commands:
  create      create the VM, with Docker installed (about 2 minutes)
  ssh         open a session on it, with RailDash's port forwarded to this machine
              (waits for Docker if it's still installing, and adds you to the docker
              group unless someone else made the VM)
  start       start a stopped VM
  stop        stop it (its disk is kept, and still bills, about $2 a month)
  delete      delete it and its disk (it asks you to type the VM's name first)
  status      say whether it exists and is running

Options:
  --project PROJECT   the Google Cloud project (default: gcloud's current project)
  --zone ZONE         the zone (default: us-east1-b)
  --name NAME         the VM's name (default: datrail-<your Google account name>)
  --port PORT         RailDash's port, on the VM and on this machine (default: 8000)
  --machine-type TYPE for create, the VM's machine type (default: e2-medium, 2 vCPU and
                      4 GB, enough for DatRail and a small agent; e2-standard-4 builds
                      from source faster and leaves room for a larger agent)
  -y, --yes           delete without asking
  -h, --help          this text
USAGE
}

die() { echo "gcp-vm.sh: $*" >&2; exit 1; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 1; }
shift
project=""
zone="us-east1-b"
name=""
port=8000
machine_type=""
yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project="${2:?--project needs a value}"; shift 2 ;;
    --zone) zone="${2:?--zone needs a value}"; shift 2 ;;
    --name) name="${2:?--name needs a value}"; shift 2 ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --machine-type) machine_type="${2:?--machine-type needs a value}"; shift 2 ;;
    -y|--yes) yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
case "$cmd" in -h|--help) usage; exit 0 ;; esac
# The machine type is set when the VM is made; changing an existing one is
# gcloud's: stop it, then `gcloud compute instances set-machine-type`.
if [ -n "$machine_type" ] && [ "$cmd" != create ]; then
  die "--machine-type is for create; to change an existing VM's, stop it and run: gcloud compute instances set-machine-type NAME --machine-type TYPE --zone ZONE"
fi
machine_type="${machine_type:-e2-medium}"
case "$machine_type" in
  -* | *[!a-z0-9-]*) die "--machine-type takes a machine type such as e2-medium or e2-standard-4, not $machine_type" ;;
esac

command -v gcloud >/dev/null 2>&1 || die "gcloud isn't installed. Install the Google Cloud CLI first: https://cloud.google.com/sdk/docs/install"
if [ -z "$project" ]; then
  project="$(gcloud config get-value project 2>/dev/null || true)"
  [ -n "$project" ] || die "no project given and gcloud has none set. Pass --project, or run: gcloud config set project PROJECT"
fi
account="$(gcloud config get-value account 2>/dev/null || true)"
[ -n "$account" ] || die "gcloud isn't signed in. Run: gcloud auth login"
# Who made the VM, as a label: lowercase letters, digits, - and _, up to 63 characters.
owner="$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | cut -c1-63)"
if [ -z "$name" ]; then
  # From the Google account rather than the local login, which is often the same for
  # everyone (root, ubuntu, vscode).
  user="$(printf '%s' "${account%@*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g' | cut -c1-50 | sed 's/-*$//')"
  name="datrail-${user:-vm}"
fi
region="${zone%-*}"
g=(--project "$project" --zone "$zone")

# What the VM runs once at its first boot: Docker Engine and Compose from Docker's apt
# repository, then a marker file the ssh session waits for (session_script, below).
# shellcheck disable=SC2016 # expands on the VM, not here
startup_script='#!/bin/bash
set -e
[ -f /var/lib/datrail-vm/ready ] && exit 0
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
mkdir -p /var/lib/datrail-vm && touch /var/lib/datrail-vm/ready'

# What the ssh command runs on the VM in place of a plain login shell. It waits up to 5
# minutes for the startup script to install Docker (Docker's socket counts as ready too,
# for a VM this script didn't create). If you aren't in the docker group, it adds you, so
# docker works without sudo; not on a VM someone else made, where ssh sets join_group=no.
# Then it opens your shell: a fresh login through sudo when the group is new to this
# session, so it applies without connecting again, otherwise your login shell. After 5
# minutes without Docker it leaves the group alone and opens the shell anyway. The docker
# group is equivalent to root on the VM, which is fine on a test VM of your own.
# shellcheck disable=SC2016 # expands on the VM, not here
session_script='ready=/var/lib/datrail-vm/ready
docker_ready() { [ -e "$ready" ] || [ -S /var/run/docker.sock ]; }
in_docker_group() { id -nG "$@" 2>/dev/null | tr " " "\n" | grep -qx docker; }
if ! docker_ready; then
  echo "Docker is still installing on the VM (usually about 2 minutes after create). Waiting..."
  waited=0
  while ! docker_ready && [ "$waited" -lt 300 ]; do
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 60)) -eq 0 ] && ! docker_ready; then echo "Still installing, $((waited / 60)) min so far..."; fi
  done
  if docker_ready; then
    echo "Docker is ready."
  else
    echo "Docker has still not finished installing after 5 minutes. To see why, run on the VM:"
    echo "  sudo journalctl -u google-startup-scripts -n 50"
    echo "Opening a shell anyway."
  fi
fi
if [ "${join_group:-yes}" = yes ] && docker_ready && ! in_docker_group "$USER"; then
  if sudo -n usermod -aG docker "$USER"; then
    echo "Added $USER to the docker group, so docker works without sudo."
  else
    echo "Could not add $USER to the docker group. Your account needs the Compute OS Admin Login role (docs/setup-gcp-vm.md, Before you start)."
  fi
fi
if in_docker_group "$USER" && ! in_docker_group && sudo -n true 2>/dev/null; then
  exec sudo -n -i -u "$USER"
fi
exec "${SHELL:-/bin/bash}" -l'

# gcloud says TERMINATED for a stopped VM.
pretty() { case "$1" in TERMINATED) echo stopped ;; *) echo "$1" | tr '[:upper:]' '[:lower:]' ;; esac; }

# Both print nothing when the VM doesn't exist. gcloud fails then, and under set -e that
# would end the script before it could say so.
exists() { gcloud compute instances describe "$name" "${g[@]}" --format='value(status)' 2>/dev/null || true; }
owner_of() { gcloud compute instances describe "$name" "${g[@]}" --format='value(labels.owner)' 2>/dev/null || true; }
not_mine() { theirs="$(owner_of)"; [ -n "$theirs" ] && [ "$theirs" != "$owner" ]; }

case "$cmd" in
  create)
    if [ -n "$(exists)" ]; then
      not_mine && die "$name already exists in $project ($zone) and someone else made it ($theirs). Pass --name to make your own"
      die "$name already exists in $project ($zone). Use: gcp-vm.sh start, or pass --name"
    fi
    # Without an external IP the VM needs a Cloud NAT in its region to reach Docker, GitHub
    # and ghcr.io. Many organisations forbid external IPs, so this does not add one.
    if [ -z "$(gcloud compute routers list --project "$project" --filter="region:$region AND nats:*" --format='value(name)' 2>/dev/null)" ]; then
      die "the default network has no Cloud NAT in $region, so a VM without an external IP can't download anything. Ask your project admin to add one, or create it: docs/setup-gcp-vm.md, Troubleshooting, has the two commands"
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    printf '%s\n' "$startup_script" > "$tmp"
    echo "Creating $name in $project ($zone): $machine_type, Ubuntu 24.04, no external IP"
    gcloud compute instances create "$name" "${g[@]}" \
      --machine-type "$machine_type" \
      --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
      --boot-disk-size 50GB --boot-disk-type pd-balanced \
      --no-address \
      --metadata enable-oslogin=TRUE \
      --metadata-from-file startup-script="$tmp" \
      --labels "purpose=datrail,created-by=gcp-vm-sh,owner=$owner" \
      --verbosity=error \
      --format='value(name)' >/dev/null
    echo "Created. Docker installs in the background over the next 2 minutes or so."
    echo "Next: gcp-vm.sh ssh${project:+ --project $project} --zone $zone --name $name"
    ;;
  ssh)
    status="$(exists)"
    [ -n "$status" ] || die "$name doesn't exist in $project ($zone). Create it: gcp-vm.sh create"
    [ "$status" = "RUNNING" ] || die "$name is $(pretty "$status"). Start it: gcp-vm.sh start"
    echo "Connecting to $name. RailDash will be at http://127.0.0.1:$port on this machine while this session is open."
    # On a VM someone else made, a session only: its docker group is the owner's to change.
    session="$session_script"
    if not_mine; then
      echo "Someone else made $name ($theirs), so this won't add you to its docker group."
      session="join_group=no
$session_script"
    fi
    # A terminal for the shell at the end of session_script, when there is one here.
    ssh_args=(-L "$port:127.0.0.1:$port")
    if [ -t 0 ]; then ssh_args=(-t "${ssh_args[@]}"); fi
    for try in 1 2 3 4 5 6; do
      rc=0
      gcloud compute ssh "$name" "${g[@]}" --tunnel-through-iap --command "$session" -- "${ssh_args[@]}" || rc=$?
      [ "$rc" -ne 0 ] || exit 0
      [ "$rc" -eq 255 ] || exit "$rc"
      echo "The VM isn't answering SSH yet (it may still be booting). Trying again in 15 seconds ($try of 6)."
      sleep 15
    done
    die "couldn't connect after 6 tries. docs/setup-gcp-vm.md, Troubleshooting, has what to check"
    ;;
  start)
    [ -n "$(exists)" ] || die "$name doesn't exist in $project ($zone). Create it: gcp-vm.sh create"
    gcloud compute instances start "$name" "${g[@]}" --quiet
    echo "Started. Next: gcp-vm.sh ssh"
    ;;
  stop)
    [ -n "$(exists)" ] || die "$name doesn't exist in $project ($zone)"
    gcloud compute instances stop "$name" "${g[@]}" --quiet
    echo "Stopped. Its disk is kept and still bills (about \$2 a month). gcp-vm.sh delete removes it."
    ;;
  delete)
    [ -n "$(exists)" ] || die "$name doesn't exist in $project ($zone)"
    not_mine && die "someone else made $name ($theirs), so this won't delete it. Pass --name for your own VM"
    if [ "$yes" -ne 1 ]; then
      [ -t 0 ] || die "delete asks before it deletes. Run it in a terminal, or pass --yes"
      printf 'This deletes %s and its disk in %s (%s), and cannot be undone.\nType the VM name to confirm: ' "$name" "$project" "$zone"
      read -r answer
      [ "$answer" = "$name" ] || die "not deleted"
    fi
    gcloud compute instances delete "$name" "${g[@]}" --quiet
    echo "Deleted $name and its disk."
    ;;
  status)
    status="$(exists)"
    if [ -n "$status" ]; then echo "$name in $project ($zone): $(pretty "$status")"; else echo "$name doesn't exist in $project ($zone)"; fi
    ;;
  *) die "unknown command: $cmd (see --help)" ;;
esac
